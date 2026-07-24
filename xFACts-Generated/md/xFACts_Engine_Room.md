# The Engine Room

*The plumbing, the wiring, the permissions, and the guy who keeps it all running on time*

The Engine Room doesn't monitor anything itself. It's the shared infrastructure that every module in xFACts depends on — the scheduler that runs everything on time, the configuration system that makes things adjustable without code changes, the version tracking that knows what's deployed, the safety net that prevents accidental destruction, and the permission system that controls who can see what and do what.






The Problem

When you build a monitoring platform, the first thing you build is a monitoring script. Then another one. Then a third. Pretty soon you've got a dozen scripts that all need to run on different schedules, and you're using SQL Agent jobs to coordinate them, and it takes three and a half minutes of overhead just to figure out what's due to run.

Then someone asks "what version of that procedure is in production?" and you realize you don't actually know. 

Then someone asks "where are the passwords stored?" and you hope the answer isn't "in plain text in the script." 

(Except that it is - just go ask a developer where the passwords for the python scripts are...) 

Then someone almost drops a table in production by accident and you realize there's nothing stopping them except luck.

Then someone says "can my team use this?" and you realize that "everyone can do everything" is a great policy right up until someone moves a production job to the wrong server during lunch.

The Engine Room exists because every one of those things happened. These are the problems you solve after the monitoring works but before you can sleep at night.






Meet Mo


The word "orchestrator" can be a bit triggering for certain individuals around here. So when it came time to name the thing that coordinates all of xFACts' processes, we went with "Mo" instead. Short for Master Orchestrator. Matt's blood pressure stays normal. Everyone wins.


Mo is a service that runs continuously on its own server. On a configurable heartbeat, he wakes up, checks what needs to run, runs it, logs what happened, and goes back to sleep. He doesn't know or care what the individual modules do. JobFlow monitors job flows. ServerOps watches disk space. BIDATA checks the data warehouse. Mo just calls each one when it's time and writes down what happened. Very zen. Very reliable.



Wake Up
→
Check What's
Due
→
Run It
→
Log What
Happened
→
Sleep

Mo's heartbeat cycle — continuously, forever


The beauty of it is that nothing is hardcoded. Want to temporarily disable a process during maintenance? Change a flag. Want to adjust how often something runs? Update the interval. Want to add an entirely new monitoring process? Add a row. No code changes. No service restarts. Mo adapts on the next heartbeat.


**Historical note:** Mo had a predecessor — a stored procedure running inside a SQL Agent job. Same concept, far less capable. Fixed five-minute cycle for everything, no output capture, and over three minutes of overhead per run. The current Mo runs as a dedicated service with per-process scheduling, full output capture, and sub-second overhead. Mo Sr. served well. Mo Jr. just has a better résumé.







The Toolkit

Beyond Mo, the Engine Room provides the shared tools that every module relies on. Think of it as the building's infrastructure — you don't notice the electrical panel, the security desk, or the HVAC system until one of them stops working.

**Configuration.** Almost everything in xFACts that can be adjusted lives in one table. Alert thresholds, feature toggles, timing windows, display settings. Change a value, and within minutes every script and every dashboard page is using it. Nobody edits code to change a threshold. That's the whole point.

**Version tracking.** Every table, procedure, trigger, and script in xFACts is cataloged and versioned at the component level. When something changes, a version entry is recorded with what changed, when, and by whom. The history accumulates naturally — no more archaeology expeditions through source control to answer "what was running last Tuesday?"

**Credentials.** External integrations need API keys, webhook URLs, and passwords. Those are stored encrypted in the database with a two-tier encryption model. Scripts retrieve what they need at runtime. Nothing sensitive lives on disk. Nothing sensitive lives in a script file.

**Holidays.** Several modules need to know whether today is a business day. File monitoring schedules, index maintenance windows, and batch processing expectations all change on holidays. One shared calendar, consumed by any module that needs it.

**Audit trails.** Who changed that configuration setting? Did that Teams alert actually get delivered? When did that script last run, and what happened? The Engine Room maintains multiple audit trails so that when someone asks "what happened?" at 9 AM, the evidence is already there.






The Safety Net

Accidents happen. Someone runs a script in the wrong database. Someone tries to drop a table they thought was temporary. Someone gets a little too comfortable with the DELETE key at 4:45 PM on a Friday.

A protection system intercepts destructive commands and checks if the target is a critical xFACts object. If it is? Blocked. Rolled back. Logged. This isn't security — database permissions handle that. This is a safety net against *mistakes*. The kind that happen when you're in a hurry and the wrong query window is active.

*"I'm sorry, Dave. I'm afraid I can't do that."*






Who Gets In

Once you build a dashboard with buttons that do things — useful things, dangerous things, *fun* things — someone's going to ask "can my team use this?" And now you have questions that keep you up at night. Can they see everything? Should they? What about that button that moves production jobs between servers?

The permission system answers three questions for every user on every page:

| Question | Short Answer |
| --- | --- |
| Are you who you say you are? | Active Directory handles this — same login as your computer |
| Are you allowed to be here? | Your AD group maps to a role, and roles determine which pages you can access |
| Are you allowed to do *that*? | Each button and action has its own permission check — looking doesn't mean touching |


Adding a new team is entirely configuration — create the AD groups, add the role mappings, and they're in. No code changes. No deployment. IT manages *who you are*. The Applications Team manages *what that means*. Neither team needs to coordinate with the other for routine access changes.






The Bottom Line

The Engine Room is the foundation that makes xFACts work. Mo keeps the trains running on time. The configuration system makes changes painless. The version tracking maintains history. The protection prevents disasters. The credentials keep secrets safe. The permissions make sure the right people see the right things.

None of it is exciting. All of it is necessary.

When you're troubleshooting at 2 AM and you can see exactly what ran, when, and what failed — that's the Engine Room. When someone almost drops a critical table and gets stopped — that's the Engine Room. When a new department gets access to their own dashboard without anyone writing a single line of code — still the Engine Room.

It's infrastructure. It's supposed to be invisible. But it's nice to know it's there, quietly making sure everything else can shine.

---

## Architecture
# Engine Room Architecture

The Engine Room narrative tells you *what* lives here and *why*. This page tells you *how*. Three systems — the orchestrator, shared infrastructure, and RBAC — each with their own tables, their own lifecycle, and their own opinions about how things should work. Here's how the data actually moves.



The Orchestrator — Data Lifecycle

Three tables. That's all the orchestrator needs to manage every automated process in xFACts. One for configuration, two for history. They're deceptively simple, and understanding how data flows between them explains everything about how Mo works.



ProcessRegistry — The Living Schedule

`Orchestrator.ProcessRegistry` is both configuration and runtime state in one table. Each row defines a process — what to run, how often, what dependency group it belongs to — but it also tracks the current execution state. Fields like `last_execution_dttm`, `last_execution_status`, and `running_count` are updated by Mo on every heartbeat. The schedule is the state.

This dual nature is what makes configuration changes instant. Update `interval_seconds` and Mo uses the new value on the very next heartbeat. Set `run_mode` to 0 and the process stops running. No restarts, no deployments, no waiting for a config file to get picked up. The schedule is always live because it's always being read.


The three run modes: `run_mode = 0` means disabled — Mo skips it entirely. `run_mode = 1` is standard scheduled execution — every data collector, every monitoring script, every daily summary runs in this mode. It's the workhorse. `run_mode = 2` is queue-driven — the process only runs when something signals demand. Teams and Jira queue processors use this.


The Heartbeat Cycle

When Mo wakes up and finds work to do, the first thing he creates is a `CycleLog` entry. This is the parent record — one row per heartbeat that actually executed something. It starts with a timestamp and a status of RUNNING.

Then Mo works through the due processes, one at a time within each dependency group. For each process, he creates a `TaskLog` entry linked back to the CycleLog via `cycle_id`. The TaskLog captures everything: the process name, the actual script or procedure that ran, the execution mode, timing, exit codes, and the full stdout/stderr output.

When the cycle finishes, Mo goes back and updates the CycleLog with the final counts — tasks due, executed, succeeded, failed, skipped — and marks it SUCCESS or PARTIAL depending on the results.





Wake
Heartbeat fires
(configurable interval)

→

Query Due
Check ProcessRegistry
for due processes

→

Create CycleLog
Parent record
status = RUNNING

→

Execute
Each process by
dependency group
Create TaskLog per task

→

Finalize
Update CycleLog
with final counts

→

Sleep
Wait for next
heartbeat


If no processes are due, Mo skips the cycle entirely — no CycleLog entry, no wasted effort.



Denormalized by design: TaskLog stores the module name, process name, dependency group, and execution target directly in each row, even though it has a foreign key back to ProcessRegistry. This is intentional. If a process gets renamed, reconfigured, or removed, the historical log entries remain accurate. The TaskLog record is a snapshot of what actually happened, not a pointer to what the configuration looks like *now*.


WAIT vs. FIRE_AND_FORGET

In WAIT mode, Mo launches the script, captures the output, updates the TaskLog with the result, and moves on. The whole thing takes seconds. Simple.

FIRE_AND_FORGET is for the heavy lifters — backup network copies, large data transfers, anything that would block the pipeline for minutes. The lifecycle looks different:

Mo creates the TaskLog entry and marks it RUNNING. He launches the script in the background, immediately updates the TaskLog to LAUNCHED, resets the `running_count` in ProcessRegistry, and moves on to the next process. He's done with it.

The launched script is now on its own. When it finishes, it dot-sources `xFACts-OrchestratorFunctions.ps1` and calls `Complete-OrchestratorTask`, passing back its task ID, process ID, status, duration, and any output. That callback function updates the TaskLog entry with the final result and decrements `running_count` in ProcessRegistry. It also fires a `Send-EngineEvent` to push the completion notification to the Control Center in real time.

Two different execution patterns, same final state in the database. The CycleLog and TaskLog don't care how the result got there.

Queue-Driven Processing

The Teams and Jira queue processors add a third pattern. These are the `run_mode = 2` processes — they don't run on a timer, they respond to demand.

When a module queues an alert (say, a Teams notification), the queue table's depth trigger fires and increments `running_count` on the queue processor's ProcessRegistry entry. On the next heartbeat, Mo sees a positive `running_count` for a `run_mode = 2` process and launches it. The processor drains the queue, and Mo resets the count to zero.

If more alerts arrive while the processor is running, the trigger increments the count again. Mo picks it up on the next heartbeat. No polling interval to tune, no wasted cycles checking an empty queue. Items get processed within seconds of being queued.






Shared Infrastructure — The Connective Tissue

The shared infrastructure tables in the `dbo` schema don't form a single interconnected system the way the orchestrator tables do. They're more like utilities — each one serving a specific purpose, consumed by whatever module needs it. But they have relationships worth understanding, and a few of them are more clever than they look.



GlobalConfig — How It Gets Read

Every module in xFACts reads from `dbo.GlobalConfig`, but the way they read it differs. Backend PowerShell scripts query GlobalConfig at the start of each execution, pulling the settings they need for that run. The Control Center reads it differently — settings are cached in memory at startup and refreshed periodically, so a setting change takes effect within minutes across all dashboards.

The table itself is straightforward: module name, component, setting name, value, data type, and a description. But the organizational convention matters. Settings are namespaced by module and component, which means you can pull everything the Backup module needs with a single `WHERE module_name = 'ServerOps' AND category = 'Backup'` filter. Every script does exactly that.


No foreign keys, by design: GlobalConfig has no foreign key relationships to anything. It's a pure key-value store with metadata. Modules reference it by convention (matching on module/category/setting name), not by constraint. This keeps it flexible — any module can add settings without schema changes, and removing a module's settings is just a DELETE statement.


The Version Tracking System

Version tracking is built on a four-table hierarchy that separates *what exists* from *what changed*:

| Table | Role | Granularity |
| --- | --- | --- |
| `dbo.Module_Registry` | Top-level functional domains | ServerOps, JobFlow, BatchOps, etc. |
| `dbo.Component_Registry` | Logical groupings within a module | ServerOps.Backup, ServerOps.Index, etc. |
| `dbo.Object_Registry` | Individual objects linked to their parent component | Tables, scripts, CC files, docs |
| `dbo.System_Metadata` | Append-only version changelog | One row per version bump per component |


Versioning happens at the **component level**, not per-object. A single version bump covers all objects touched within a component during a development session. The description field carries the detail about what changed. Version numbers follow a sequential counter pattern with no semantic meaning — each bump is just the next number.

The current version for any component is simply the most recent row in `System_Metadata` for that component. The table is append-only — no status columns, no triggers, no supersession logic. History is preserved by the natural accumulation of rows.


Legacy data preserved. The previous per-object System_Metadata table (which used ACTIVE/SUPERSEDED statuses and an auto-supersede trigger) is preserved as `Legacy.System_Metadata`. All historical version data remains accessible there. The current table started fresh at version 3.0.0 per component to maintain continuity with legacy version numbering.


The Credential Vault

Two tables work in tandem for credential management. `dbo.CredentialServices` defines what external services exist — JiraAPI, TeamsWebhook, SFTP — essentially a registry of integration points. `dbo.Credentials` stores the actual encrypted values for each service, organized by environment.

The encryption uses a two-tier model. A master passphrase lives in GlobalConfig. That master passphrase decrypts a per-service passphrase stored in the Credentials table. That per-service passphrase then decrypts the actual username and password. Two layers of decryption, all happening in a SQL query at runtime. The decrypted values exist only in memory, only for the duration of the script execution, and never touch the filesystem.

Adding a new integration is two INSERTs: one row in CredentialServices to define the service, one row in Credentials with the encrypted values. Every script that needs credentials uses the same retrieval pattern — pass in the service name, get back the decrypted username and password. The scripts don't know or care about the encryption mechanics.


Exception: AWS CLI credentials. The AWS S3 upload process uses the AWS CLI, which reads credentials from the service account's user profile on FA-SQLDBB rather than from the Credentials table. This is the one integration that doesn't follow the standard credential retrieval pattern.


Server and Database Registries

`dbo.ServerRegistry` and `dbo.DatabaseRegistry` are the enrollment tables. ServerRegistry defines which SQL Server instances xFACts monitors, with flags controlling which monitoring features are enabled for each server (activity monitoring, backup monitoring, index maintenance, etc.). DatabaseRegistry extends this to the database level, linking each database to its parent server.

Multiple modules consume these registries. The server health collector reads ServerRegistry to know which servers to poll. The backup monitor reads it to know which servers have backup tracking enabled. The index maintenance engine reads DatabaseRegistry to know which databases participate in automated index operations. One set of enrollment tables, consumed by many scripts.

The Protection Chain

Three objects form the DDL protection system: the trigger, the logging procedure, and the violation log.

`TR_xFACts_ProtectCriticalObjects` fires on DDL events (DROP, ALTER) and checks the target object against a hardcoded list. If the object is protected, the trigger needs to log the attempt *before* rolling back the transaction. That's the problem — a ROLLBACK inside a trigger undoes everything in the transaction, including any INSERT you just did.

The solution is `sp_LogProtectionViolation`, which uses a loopback linked server to execute the INSERT in a separate, autonomous transaction. The trigger calls this procedure, the procedure logs to `Protection_ViolationLog` through the linked server, and then the trigger rolls back the DDL. The violation log entry survives because it was committed in its own transaction. Clever, slightly terrifying, and completely necessary.


Why a loopback linked server? SQL Server doesn't support autonomous transactions natively. The loopback linked server (configured as `xFACts_Loopback`) connects back to the same instance, but from the trigger's perspective it's a remote call. The INSERT through the linked server commits independently of the trigger's transaction. This pattern exists on every AG node.


The Audit Trail

Two tables capture different kinds of platform activity. `dbo.ActionAuditLog` records deliberate human actions through the Control Center — configuration changes, manual triggers, administrative operations. Each entry captures who did it, what they did, and the before/after values. This is the "who changed that setting?" table.

`dbo.API_RequestLog` records outbound integration activity — every REST API call to Jira, Teams, or other services. Status codes, response times, request/response payloads. This is the "did that Teams alert actually get delivered?" table.

Together with the CycleLog/TaskLog (automated execution), RBAC_AuditLog (access decisions), and Protection_ViolationLog (blocked DDL), xFACts maintains five distinct audit trails covering every category of platform activity.






RBAC — The Permission Pipeline

Seven tables, one question: "Can this person do this thing?" The answer takes about a millisecond, but the path through the data is worth walking through because every table has a specific job and they chain together in a specific order.



The Lookup Chain

When a user hits a Control Center page, here's the data path:

**Step 1: Identity.** Active Directory authenticates the user and provides their group memberships. This happens at the Pode framework level before any xFACts code runs.

**Step 2: Role resolution.** The middleware takes those AD group names and looks them up in `RBAC_RoleMapping`. Each matching row maps an AD group to a `role_id`, optionally scoped to a department. A user in multiple AD groups can end up with multiple roles. That's fine — more roles means more potential access, and the system takes the best case.

**Step 3: Page access.** With the user's roles resolved, the middleware checks `RBAC_PermissionMapping` for any row matching one of those role IDs and the current page route. Each matching row specifies a permission tier (admin, operate, or view). If multiple roles grant access to the same page, the highest tier wins. The Admin role has a wildcard `page_route = '*'` that matches everything.

**Step 4: Rendering.** The page renders at the user's resolved tier. Admin sees everything. Operate sees action buttons but not dangerous operations. View sees data displays only. The tier value flows down to every UI component on the page.


All from cache: None of these lookups hit the database in real time. All RBAC tables are loaded into a PowerShell hashtable on Control Center startup and refreshed on a configurable interval. The permission check is a series of in-memory hashtable lookups, which is why it takes about a millisecond. The trade-off is that AD group changes take a few minutes to take effect.


Action Permission — The Override Layer

Page-level tiers handle most access decisions. But when a user clicks a button that triggers an API call, a second evaluation runs.

`RBAC_ActionRegistry` is the master catalog of protected endpoints. Each row defines an action: its name, the API endpoint path, the HTTP method, which page it belongs to, and what tier is normally required. A route handler checks this by calling `Test-ActionEndpoint` at the top of its scriptblock — one line of code.

Before falling back to the tier check, the system looks for overrides in `RBAC_ActionGrant`. This is where the five-step evaluation order matters:

First, check for a user-level DENY. If this specific user has a DENY grant for this specific action, stop immediately. Blocked.

Second, check for a role-level DENY. If any of the user's roles have a DENY grant for this action, stop. Blocked.

Third, check for a user-level ALLOW. If this specific user has an ALLOW grant, permit it regardless of their tier.

Fourth, check for a role-level ALLOW. Same logic, but for any of the user's roles.

Fifth, fall back to the tier check. Does the user's page tier meet or exceed the action's `required_tier`? If yes, permitted. If no, blocked.

DENY always wins over ALLOW at the same scope level. User-level grants override role-level grants within the same grant type. The system is designed so that it's easier to accidentally over-restrict than over-permit.

Department Scoping

`RBAC_DepartmentRegistry` links department identifiers to their page routes and display names. It doesn't have foreign key relationships to the other RBAC tables — the connection is through the `department_scope` string value in RoleMapping.

When a role mapping has a `department_scope` value (like `business-services`), that role only grants access to pages registered under that department. The same `DeptStaff` role can be reused across departments — scope it to `business-services` for one AD group and `client-relations` for another. Same role definition, different access. Adding a new department is entirely configuration: register the department, create the AD groups, add the role mappings. Zero code changes.

The Enforcement Lifecycle

RBAC doesn't jump straight from "off" to "enforced." The `rbac_enforcement_mode` GlobalConfig setting controls a three-stage progression.

In `disabled` mode, the middleware skips all permission checks. Everyone sees everything. This is where you start while IT Ops creates the AD groups and the Applications Team builds the role mappings.

In `audit` mode, every permission check runs but nothing gets blocked. When a check *would* deny access, it logs a `WOULD_DENY` entry to `RBAC_AuditLog` instead of returning a 403. The user gets in, but the audit trail shows exactly who would be affected by enforcement. Run this for a week. Check the log. Fix the mappings that need fixing. When the only WOULD_DENY entries are for people who genuinely shouldn't have access, you're ready.

In `enforce` mode, denials are real. No access means a 403 response and a `DENIED` entry in the audit log. The transition from audit to enforce should be boring. If you did the audit phase right, nothing surprising happens.


Audit verbosity: A second GlobalConfig setting (`rbac_audit_verbosity`) controls how much gets logged during enforcement. Set to `denials_only` (the default), only DENIED and WOULD_DENY events are recorded. Set to `all`, every permission check — including successful ones — gets an audit entry. Use `all` temporarily for compliance audits or when debugging access issues, then switch back to avoid filling the table unnecessarily.


The Audit Log Structure

`RBAC_AuditLog` is deliberately denormalized. When a permission event is logged, the entry captures the user's AD groups and resolved roles as comma-separated strings rather than foreign key references. This is the right call — the audit log needs to reflect the state at the *time of the event*, not the current state of the RBAC tables. If someone's roles change next week, the audit record for today's denial still shows exactly what roles they had when they were denied.

The table is append-only. No updates, no deletes (outside of periodic retention cleanup). Every event type — LOGIN_SUCCESS, LOGIN_FAILURE, PAGE_DENIED, ACTION_DENIED, ACTION_ALLOWED, CONFIG_CHANGE — captures the relevant context for that event type. Page and action fields are NULL for login events. Action fields are NULL for page-level checks. The schema adapts to what each event type needs.






Troubleshooting

**"Is the orchestrator running?"**
Check the NSSM service: `nssm status xFACtsOrchestrator` on FA-SQLDBB. Or look at the engine health indicators on any Control Center page — if the countdown is ticking, Mo is alive.

**"A process isn't executing."**
Check `Orchestrator.ProcessRegistry`: is the process enabled (`run_mode = 1` or `2`)? Is it stuck in a running state (`running_count > 0` from a previous timeout)? Is the interval longer than you think? For time-based processes, has the scheduled time passed today?

**"Something failed — what happened?"**
Check `Orchestrator.TaskLog` for that process. The `error_output` column has the full stderr from the script. This is the #1 advantage of Mo Jr. over Mo Sr. — you actually get to see what went wrong.

**"Who changed a GlobalConfig setting?"**
Check `dbo.ActionAuditLog`. Every Control Center config change is logged with the before and after values.

**"Someone tried to drop a table — was it blocked?"**
Check `dbo.Protection_ViolationLog`. If it was a protected object, the full details are there including the SQL text of the command.

**"A user says they can't access a page."**
Check `dbo.RBAC_AuditLog` for DENIED entries with their username. The log shows their resolved roles, tier, and what tier was required. If RBAC is in audit mode, look for WOULD_DENY entries instead.

**"I added someone to an AD group but they still can't get in."**
RBAC data is cached and refreshes on a configurable interval. Wait for the cache to refresh, or restart the Control Center to force an immediate reload.






How Everything Connects

The three systems in the Engine Room don't have foreign key relationships between them, but they interact through shared patterns and data.

**GlobalConfig is the universal settings layer.** The orchestrator reads its heartbeat interval from GlobalConfig. RBAC reads its enforcement mode and audit verbosity from GlobalConfig. Every module reads its alert thresholds, feature toggles, and timing windows from GlobalConfig. It's the one table that every component in xFACts depends on, and it has no idea any of them exist.

**The orchestrator drives everything else.** Every monitoring script, every queue processor, every data collector runs because Mo launched it. The RBAC tables aren't populated by the orchestrator (they're configuration), but the Control Center that *reads* those tables is being served by the same infrastructure that Mo coordinates. If Mo stops, the monitoring stops. If the monitoring stops, there's nothing for RBAC to protect access to.

**System_Metadata tracks all three.** Orchestrator tables, shared infrastructure tables, and RBAC tables all have version entries in System_Metadata. It's the one place that knows about everything, even though it doesn't interact with anything.

**The protection trigger guards all three.** Orchestrator tables, shared infrastructure tables, and RBAC tables are all in the protected object list. The trigger doesn't know what a "module" is — it just knows the name of every table, procedure, and trigger that matters, and it blocks anyone who tries to drop one.

**Five audit trails, one platform.** CycleLog and TaskLog track automated execution. ActionAuditLog tracks human actions. API_RequestLog tracks outbound integrations. RBAC_AuditLog tracks access decisions. Protection_ViolationLog tracks blocked DDL. No single table tells the whole story, but together they cover everything.

---

## Reference

### dbo

### ActionAuditLog

Centralized audit trail for all user-initiated actions in the Control Center. Captures configuration changes, schedule edits, job triggers, BDL imports, access grants, alert resends, and any other operational action performed through the UI.

**Data Flow:** Populated by Control Center API route handlers whenever a user performs an action through any CC page. Each discrete action generates one row with a human-readable summary. Rows are append-only and never updated or deleted.

**Action Summary Pattern:** [sort:1] Each row captures a single user action with a human-readable action_summary string built by the calling code. The summary includes all relevant context (e.g., "Changed orchestrator_drain_mode from 0 to 1" or "Triggered Refresh Drools (3 servers)"). This avoids structured old/new value columns in favor of flexibility across diverse action types.

**Cooldown Enforcement:** [sort:2] Operational actions with cooldown periods (e.g., Balance Sync at 60 minutes) query the most recent successful execution by action_type, action_summary pattern, and environment to determine eligibility. The table serves as both audit trail and throttle source.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| audit_id (IDENTITY) | int | No | IDENTITY | Primary key identity. |
| page_route | varchar(100) | No | — | Control Center page route where the action originated (e.g., /admin, /bdl-import, /apps-int). |
| action_type | varchar(50) | No | — | Action category: CONFIG_CHANGE, SCHEDULE_CHANGE, JOB_TRIGGER, BDL_IMPORT, ACCESS_CHANGE, ALERT_RESEND. |
| action_summary | varchar(1000) | No | — | Human-readable description of what happened, built by the calling code to capture essential context in a single string. |
| environment | varchar(20) | Yes | — | Target DM environment for environment-scoped actions (TEST, STAGE, PROD). NULL for actions that are not environment-specific. |
| result | varchar(20) | Yes | — | Outcome for operational actions: SUCCESS or FAILED. NULL for instant actions like config changes. |
| error_detail | varchar(500) | Yes | — | Error message captured on failure. NULL on success or for action types where result is not tracked. |
| executed_by | varchar(100) | No | — | AD username of the user who performed the action (FAC\ domain prefix). |
| executed_dttm | datetime2 | No | sysdatetime() | Timestamp when the action was performed. |

  - **PK__ActionAu__5AF33E336719D06A** (CLUSTERED): audit_id -- PRIMARY KEY

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| action_type | CONFIG_CHANGE | A configuration setting was modified through a Control Center administrative interface. | 1 |
| action_type | JOB_TRIGGER | A DM scheduled job or process was manually triggered through the Control Center. | 2 |

**Recent actions across all pages** [sort:1] -- Shows the most recent user actions with full context.

```sql
SELECT TOP 50 page_route, action_type, action_summary,
       environment, result, error_detail,
       executed_by, executed_dttm
FROM dbo.ActionAuditLog
ORDER BY executed_dttm DESC;
```

**Actions by type** [sort:2] -- Filtered audit history for a specific action category.

```sql
SELECT action_summary, environment, result, error_detail,
       executed_by, executed_dttm
FROM dbo.ActionAuditLog
WHERE action_type = 'JOB_TRIGGER'
ORDER BY executed_dttm DESC;
```

**Cooldown check for job triggers** [sort:3] -- Finds the most recent successful execution of a specific trigger in an environment.

```sql
SELECT TOP 1 executed_dttm
FROM dbo.ActionAuditLog
WHERE action_type = 'JOB_TRIGGER'
  AND action_summary LIKE '%Balance Sync%'
  AND environment = 'PROD'
  AND result = 'SUCCESS'
ORDER BY executed_dttm DESC;
```

  - **GlobalConfig**: [sort:1] CONFIG_CHANGE entries originating from GlobalConfig edits on the Admin page. Action summary includes the setting name and old/new values.


### API_RequestLog

Tracks API request metrics for volume and performance analysis. Initially captures Control Center API traffic with extensibility for future API sources.

**Data Flow:** Populated automatically by Pode middleware in the Control Center on every API request completion. Each row captures the endpoint, HTTP method, caller identity, response timing, and status code. The logging middleware is designed to fail silently rather than impact actual API requests. Request and response bodies are intentionally excluded to avoid storage bloat and sensitivity concerns.

**Source Application Extensibility:** [sort:1] The source_application column (currently 'ControlCenter' for all rows) allows future expansion to log API traffic from multiple applications in a single table for unified analysis.

**Silent Failure Design:** [sort:2] The logging middleware catches all exceptions internally and never throws. Logging failures must not impact the actual API request being processed. Observability should never cause the problem it's trying to detect.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| request_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the log entry |
| endpoint | varchar(500) | No | — | The API path called (e.g., /api/backup/pipeline-status) |
| http_method | varchar(10) | No | — | HTTP method (GET, POST, PUT, DELETE) |
| user_name | varchar(128) | Yes | — | Authenticated user name from AD |
| client_ip | varchar(45) | Yes | — | Client IP address (supports IPv6) |
| user_agent | varchar(500) | Yes | — | User-Agent header - identifies browser, script, or application |
| request_dttm | datetime | No | getdate() | When the request was processed |
| duration_ms | int | Yes | — | Total processing time in milliseconds |
| status_code | int | Yes | — | HTTP response status code (200, 404, 500, etc.) |
| response_bytes | bigint | Yes | — | Size of response body in bytes |
| source_application | varchar(100) | No | — | Application that logged the request (e.g., ControlCenter) |

  - **PK_API_RequestLog** (CLUSTERED): request_id -- PRIMARY KEY
  - **IX_API_RequestLog_Endpoint** (NONCLUSTERED): endpoint, request_dttm
  - **IX_API_RequestLog_RequestDttm** (NONCLUSTERED): request_dttm [includes: endpoint, duration_ms, status_code]
  - **IX_API_RequestLog_SourceApplication** (NONCLUSTERED): source_application, request_dttm

**Request volume by endpoint (last 24 hours)** [sort:1] -- Shows traffic patterns and performance per endpoint.

```sql
SELECT endpoint, COUNT(*) AS request_count,
       AVG(duration_ms) AS avg_duration_ms,
       MAX(duration_ms) AS max_duration_ms
FROM dbo.API_RequestLog
WHERE request_dttm >= DATEADD(HOUR, -24, GETDATE())
GROUP BY endpoint
ORDER BY request_count DESC;
```

**Slowest endpoints (last 24 hours)** [sort:2] -- Identifies performance bottlenecks by average response time.

```sql
SELECT endpoint, COUNT(*) AS request_count,
       AVG(duration_ms) AS avg_duration_ms,
       MAX(duration_ms) AS max_duration_ms
FROM dbo.API_RequestLog
WHERE request_dttm >= DATEADD(DAY, -1, GETDATE())
GROUP BY endpoint
ORDER BY avg_duration_ms DESC;
```


### Asset_Registry

Catalog of every component (CSS class, JS function, HTML ID, API route, etc.) extracted from Control Center source files. One row per definition or usage instance. Distinguishes local from shared scope and maps consumption to definition. Serves as both descriptive catalog (what exists, where) and prescriptive reference (naming conventions, established patterns). Populated by parser scripts that walk all CC source files, parse them via language-appropriate AST tools (PostCSS for CSS, Acorn for JS, built-in PowerShell parser for .ps1/.psm1), and produce one row per extracted component instance. Refresh strategy is truncate-and-reload per file_type, reflecting current state only with no historical retention.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| asset_id (IDENTITY) | int | No | IDENTITY | Surrogate primary key. Not stable across runs. |
| file_name | varchar(200) | No | — | The source file the row was extracted from. |
| object_registry_id | int | Yes | — | Foreign key to dbo.Object_Registry.registry_id. NULL when the file has no Object_Registry row. |
| file_type | varchar(10) | No | — | The content type extracted, not the file extension. |
| zone | varchar(20) | No | — | Partition identifier separating the Control Center catalog from the Documentation site catalog. Every USAGE row resolves only against DEFINITION rows in the same zone; cross-zone resolution does not occur. Valid values: 'cc' (Control Center application files) and 'docs' (Documentation site files). Written by every populator at row emission time based on the file path being scanned. |
| line_start | int | No | — | The 1-based source line where this construct begins. |
| line_end | int | Yes | — | The 1-based source line where this construct ends. |
| column_start | int | Yes | — | The 0-based column where this construct begins on its starting line. |
| component_type | varchar(50) | No | — | The type of construct this row represents. |
| component_name | varchar(500) | Yes | — | The construct's identifier. |
| variant_type | varchar(30) | Yes | — | Discriminates sub-flavors within a component_type. |
| variant_qualifier_1 | varchar(100) | Yes | — | First qualifier slot of the variant. |
| variant_qualifier_2 | varchar(500) | Yes | — | Second qualifier slot of the variant. |
| reference_type | varchar(20) | No | — | Whether this row defines a construct or references one. |
| scope | varchar(20) | No | — | Whether the construct lives in a curated shared file or in a page-local file. |
| source_file | varchar(200) | No | — | For DEFINITION rows, equals file_name. For USAGE rows, the file where the construct is defined. |
| source_section | varchar(300) | Yes | — | The full title of the section banner this row belongs to. |
| signature | varchar(MAX) | Yes | — | Construct-specific structural detail. |
| skeleton_hash | varchar(64) | Yes | — | Maximally loose family fingerprint of a definition's body, SHA-256 as 64 hex characters. Computed from the set of structural construct types present (for functions: control-flow constructs, returns, throws, and aggregate-builder forms), independent of their order, count, the names called, identifiers, and literals. Intended as a name-free entry point: rows sharing skeleton_hash form a loose candidate family that is then narrowed by shape_hash, body_hash, signature, and name. Deliberately coarse - common skeletons return large generic cohorts by design, and skeleton_hash is never used in isolation to make consolidation determinations. Set on the promotable DEFINITION rows each populator chooses to fingerprint; NULL where it does not apply. |
| shape_hash | varchar(64) | Yes | — | Structural fingerprint of a definition's body, SHA-256 as 64 hex characters. Same normalization as body_hash but with string and numeric literals folded to placeholder tokens and identifier references folded to a single token, while called-name and member-access names are kept literal. Two rows sharing shape_hash are the same logic differing only in literals, identifier names, casing, or formatting (combinable with little or no change). Set on the promotable DEFINITION rows each populator chooses to fingerprint; NULL where it does not apply. |
| body_hash | varchar(64) | Yes | — | Exact fingerprint of a definition's body, SHA-256 as 64 hex characters. Computed from the construct body with language-specific scaffolding removed (for functions: the declaration line, parameter block, binding/output attributes, and documentation block), remaining tokens rendered verbatim. Two rows sharing body_hash are byte-identical bodies (true copy-paste). Set on the promotable DEFINITION rows each populator chooses to fingerprint (constructs that could become shared resources, such as functions); NULL on rows where a body fingerprint does not apply. |
| has_dynamic_content | bit | Yes | — | When TRUE, the parent attribute or text construct from which this row was extracted also contains runtime-only content the populator cannot statically resolve (e.g., a class attribute that combines literal class names with a parameter-passed class name). When FALSE or NULL, the parent construct is fully captured in the catalog. Used by HTML and JS populator rows; not meaningful for CSS rows, which are always fully literal. |
| parent_function | varchar(200) | Yes | — | The enclosing context, where applicable. |
| raw_text | varchar(MAX) | Yes | — | Verbatim source text of the construct. |
| purpose_description | varchar(MAX) | Yes | — | Human-authored description of the construct, extracted from preceding comments. |
| occurrence_index | int | No | 1 | 1-based ordinal disambiguator for repeated instances within a file. |
| drift_codes | varchar(500) | Yes | — | Comma-separated list of spec-drift codes attached to this row. |
| drift_text | varchar(MAX) | Yes | — | Pipe-separated human-readable descriptions corresponding to drift_codes. |
| match_reference | varchar(500) | Yes | — | The name(s) the populator's matching criteria resolved to for this row -- a token, function, export, dispatch handler, action key, or other named construct the row was matched or resolved against. Records positive findings only, not rejected or weighed candidates; NULL when the criteria resolved to no match. Comma-space delimited when more than one match resolves. This column reports what the populator found; the drift_codes column independently reports whether that finding, or its absence, constitutes drift. |
| last_parsed_dttm | datetime2 | No | sysdatetime() | Timestamp of the run that inserted this row. |

  - **PK_Asset_Registry** (CLUSTERED): asset_id -- PRIMARY KEY
  - **IX_Asset_Registry_component_type_component_name** (NONCLUSTERED): component_type, component_name
  - **IX_Asset_Registry_drift_codes** (NONCLUSTERED): drift_codes
  - **IX_Asset_Registry_file_type_file_name** (NONCLUSTERED): file_type, file_name
  - **IX_Asset_Registry_scope_source_file** (NONCLUSTERED): scope, source_file

**Check Constraints:**

  - **CK_Asset_Registry_component_type**: `([component_type]='SQL_QUERY' OR [component_type]='RBAC_CHECK' OR [component_type]='PS_WRITE_HOST' OR [component_type]='PS_WEBSOCKET_ROUTE' OR [component_type]='PS_VARIABLE' OR [component_type]='PS_ROUTE' OR [component_type]='PS_REMOVED_CODE_COMMENT' OR [component_type]='PS_PARAMETER' OR [component_type]='PS_MIDDLEWARE' OR [component_type]='PS_INLINE_COMMENT' OR [component_type]='PS_INLINE_BANNER' OR [component_type]='PS_FUNCTION_VARIANT' OR [component_type]='PS_FUNCTION_CALL' OR [component_type]='PS_FUNCTION' OR [component_type]='PS_FILE' OR [component_type]='PS_EXPORT' OR [component_type]='PS_DOCBLOCK' OR [component_type]='PS_CONSTANT' OR [component_type]='PS_COMMENT_BLOCK' OR [component_type]='PS_CHANGELOG' OR [component_type]='MODULE_IMPORT' OR [component_type]='JS_WINDOW_ASSIGNMENT' OR [component_type]='JS_TIMER' OR [component_type]='JS_STATE' OR [component_type]='JS_METHOD_VARIANT' OR [component_type]='JS_METHOD' OR [component_type]='JS_LINE_COMMENT' OR [component_type]='JS_INLINE_STYLE' OR [component_type]='JS_INLINE_SCRIPT' OR [component_type]='JS_INLINE_EVENT' OR [component_type]='JS_IMPORT' OR [component_type]='JS_IIFE' OR [component_type]='JS_HOOK_VARIANT' OR [component_type]='JS_HOOK' OR [component_type]='JS_FUNCTION_VARIANT' OR [component_type]='JS_FUNCTION' OR [component_type]='JS_FILE' OR [component_type]='JS_EVENT' OR [component_type]='JS_EVAL' OR [component_type]='JS_DOCUMENT_WRITE' OR [component_type]='JS_DISPATCH_ENTRY' OR [component_type]='JS_CONSTANT_VARIANT' OR [component_type]='JS_CONSTANT' OR [component_type]='JS_CLASS' OR [component_type]='HTML_TEXT' OR [component_type]='HTML_SVG' OR [component_type]='HTML_ID' OR [component_type]='HTML_FILE' OR [component_type]='HTML_EVENT_HANDLER' OR [component_type]='HTML_ENTITY' OR [component_type]='HTML_DATA_ATTRIBUTE' OR [component_type]='HTML_COMMENT' OR [component_type]='GLOBALCONFIG_REF' OR [component_type]='FILE_HEADER' OR [component_type]='CSS_VARIANT' OR [component_type]='CSS_VARIABLE' OR [component_type]='CSS_RULE' OR [component_type]='CSS_KEYFRAME' OR [component_type]='CSS_FILE' OR [component_type]='CSS_CLASS' OR [component_type]='COMMENT_BANNER' OR [component_type]='CSS_LITERAL')`
  - **CK_Asset_Registry_file_type**: `([file_type]='HTML' OR [file_type]='PS' OR [file_type]='JS' OR [file_type]='CSS')`
  - **CK_Asset_Registry_reference_type**: `([reference_type]='USAGE' OR [reference_type]='DEFINITION')`
  - **CK_Asset_Registry_scope**: `([scope]='LOCAL' OR [scope]='SHARED' OR [scope]='<pending>' OR [scope]='<undefined>' OR [scope]='exempt')`
  - **CK_Asset_Registry_zone**: `([zone]='docs' OR [zone]='cc' OR [zone]='standalone' OR [zone]='exempt' OR [zone]='<undefined>')`


### ClientHierarchy

Complete flattened DM creditor hierarchy providing single-lookup resolution from any creditor to its direct parent group and ultimate top-level parent. Rebuilt daily by Sync-ClientHierarchy.ps1 using a recursive CTE against crs5_oltp creditor and creditor group tables. Standalone creditors (crdtr_grp_id = 1) self-reference — their parent and top parent fields point to themselves. Includes all creditors regardless of transaction history or active status.

**Data Flow:** Sync-ClientHierarchy.ps1 rebuilds the entire table daily via MERGE, reading from crs5_oltp.dbo.crdtr and crs5_oltp.dbo.crdtr_grp on the AG. The recursive CTE resolves the full creditor group hierarchy in a single pass. The B2B module uses this table to resolve Integration CREDITOR_NAME values (CE/CB codes) to the DM client hierarchy for crosswalk and grouping operations.

**Standalone Creditor Self-Reference:** [sort:1] Creditors assigned to crdtr_grp_id = 1 (the internal default group) are standalone — they have no meaningful group membership. Rather than NULLing the parent and top parent columns, these creditors self-reference: their parent_group and top_parent fields point back to their own creditor_id, creditor_key, and creditor_name. This avoids NULL handling in every consumer query and allows consistent GROUP BY top_parent_name behavior.

**Group 1 Exclusion:** [sort:2] The CTE anchor excludes crdtr_grp_id = 1 (DefGrp / Internal Creditor Group) to prevent duplicate path resolution. Group 1 is a system default, not a real parent. Including it would create false hierarchy paths for creditors that happen to be in the default group.

**Full Population vs Activity-Filtered:** [sort:3] This table includes ALL creditors regardless of transaction history or recency. This differs from the legacy Jira_ClientTblRanked table which filters to 13 months of activity. Full population ensures the crosswalk works for any creditor the B2B system references, even inactive or dormant ones.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| creditor_id | bigint | No | — | DM creditor identifier (crdtr_id from crs5_oltp.dbo.crdtr). Primary key. |
| creditor_key | varchar(10) | No | — | DM creditor short name (crdtr_shrt_nm) — the CE/CB code used as the crosswalk key to B2B CREDITOR_NAME. |
| creditor_name | varchar(128) | No | — | DM creditor display name (crdtr_nm). |
| parent_group_id | bigint | No | — | Direct parent creditor group identifier. Self-references creditor_id for standalone creditors (crdtr_grp_id = 1). |
| parent_group_key | varchar(10) | No | — | Direct parent group short name. Self-references creditor_key for standalone creditors. |
| parent_group_name | varchar(128) | No | — | Direct parent group display name. Self-references creditor_name for standalone creditors. |
| top_parent_id | bigint | No | — | Highest ancestor creditor group identifier resolved via recursive CTE. Self-references creditor_id for standalone creditors. |
| top_parent_key | varchar(10) | No | — | Highest ancestor group short name. Self-references creditor_key for standalone creditors. |
| top_parent_name | varchar(128) | No | — | Highest ancestor group display name. Self-references creditor_name for standalone creditors. |
| is_active | bit | No | — | Creditor active status derived from crdtr_stts_cd = 1 in crs5_oltp. |
| parent_group_is_active | bit | No | 1 | Direct parent group active status derived from crdtr_grp_sft_dlt_flg in crs5_oltp (N = active, Y = soft-deleted). For standalone creditors (self-referencing), mirrors the creditor is_active flag. Enables detection of active creditors assigned to inactive groups. |
| top_parent_is_active | bit | No | 1 | Top-level parent group active status derived from crdtr_grp_sft_dlt_flg at the highest ancestor level. For standalone creditors (self-referencing), mirrors the creditor is_active flag. Combined with parent_group_is_active and is_active, enables full hierarchy health assessment. |
| last_refreshed_dttm | datetime | No | — | Timestamp of the most recent sync cycle that wrote or confirmed this row. |

  - **PK_ClientHierarchy** (CLUSTERED): creditor_id -- PRIMARY KEY
  - **IX_ClientHierarchy_creditor_key** (NONCLUSTERED): creditor_key [includes: creditor_name, top_parent_id, top_parent_key, top_parent_name]
  - **IX_ClientHierarchy_top_parent_id** (NONCLUSTERED): top_parent_id [includes: creditor_key, creditor_name, is_active]

  - **Sync-ClientHierarchy.ps1**: [sort:1] Rebuild script that performs the full MERGE. Reads crs5_oltp.dbo.crdtr and crs5_oltp.dbo.crdtr_grp via the AG listener. Registered in ProcessRegistry for daily execution.
  - **B2B.ProcessConfig**: [sort:2] The B2B module will use ClientHierarchy to resolve Integration CREDITOR_NAME (CE/CB codes) from CLIENTS_ACCTS to the full DM hierarchy for client grouping and display.


### Component_Registry

Catalog of logical components in the xFACts platform. Each component groups related database objects, scripts, and Control Center files into a single versioned unit. Component_Registry defines what groupings exist; Object_Registry holds the individual object membership; System_Metadata tracks version history against these components.

**Data Flow:** Rows are inserted when new components are defined during platform development. Referenced by Object_Registry (FK on component_name) and System_Metadata (FK on component_name). The Admin page System Metadata modal reads Component_Registry to display the component tree and allow version bumps. New components can be added via the Admin UI. The doc_* columns drive the documentation pipeline — a JSON export (doc-registry.json) is generated from rows where doc_page_id is populated and consumed by the site navigation, Hub card grid, and documentation publisher.

**Component naming convention:** [sort:1] Components use dot notation when a module has multiple components (ServerOps.Backup, ServerOps.Index, ControlCenter.Admin). Module-level components where the module has only one component use the plain module name (JobFlow, Teams, BatchOps). This provides natural grouping in sorted displays while keeping names concise.

**Three-table versioning model:** [sort:2] Component_Registry defines the logical groupings. Object_Registry catalogs every individual object and links it to its parent component. System_Metadata tracks version history per component. The component_name column is the natural join key across all three tables. A component exists because it has a row here; its contents are in Object_Registry; its version history is in System_Metadata.

**Documentation single source of truth:** [sort:3] The doc_* columns consolidate three previously independent page registries into a single database-driven source. A JSON export (doc-registry.json) is generated by the documentation pipeline and consumed by the site navigation, the Hub card grid, and the documentation publisher. Adding a new documentation page requires only populating the doc_* columns on the component row and re-running the pipeline — no code changes needed.

**Convention-based page discovery:** [sort:4] Filenames are derived from doc_page_id by convention with standard suffixes. Child page existence is determined by filesystem check — if the file exists in the expected directory, the nav renders the link. New page types can be added by establishing a suffix convention without any schema changes.

**Multi-component pages:** [sort:5] Multiple components can share the same doc_page_id when they contribute sections to the same page. One component is the primary row (has doc_sort_order and doc_title populated). Additional components are secondary rows with only doc_page_id, doc_json_schema, doc_json_categories, and doc_section_order populated. The reference page groups and orders sections by doc_section_order.

**Index page identification:** [sort:6] The documentation site index page is identified by doc_sort_order = 0. All module pages use increments of 10 starting at 10. This convention eliminates the need for a separate boolean column and is enforced by the documentation pipeline consumers (nav.js, publisher, JSON export). Only one row should have sort order 0.

**Named CC Guide Pages:** [sort:7] The standard documentation convention is one CC guide page per pageId ({pageId}-cc.html). When a pageId needs multiple CC guide pages — because its Control Center presence spans multiple distinct pages with different functionality — the doc_cc_slug column enables named pages ({pageId}-cc-{slug}.html). The presence of any non-NULL slug for a pageId suppresses the standard single-file check in nav.js, preventing a confusing mix of generic and named links. Slug rows must also have doc_title populated for nav labels, and doc_page_id set to the parent pageId.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| component_id (IDENTITY) | int | No | IDENTITY | Auto-incrementing primary key. |
| module_name | varchar(50) | No | — | Functional module this component belongs to: dbo, ServerOps, JobFlow, BatchOps, BIDATA, FileOps, Teams, Jira, Orchestrator, ControlCenter, DeptOps. |
| component_name | varchar(128) | No | — | Unique component identifier using dot notation for scoped components (e.g., ServerOps.Backup, ControlCenter.Admin) or plain name for module-level components (e.g., JobFlow, Teams). |
| description | varchar(500) | No | — | Brief description of what this component encompasses — the functional scope and purpose. |
| cc_prefix | char(3) | Yes | — | Three-character lowercase page prefix used by CC pages to scope local CSS class names and JS top-level identifiers. NULL for shared and infrastructure components with no CC page. Source of truth for the Prefix Registry consumed by the CSS and JS asset populators during file-header validation. |
| is_active | bit | No | 1 | Soft delete flag. 1 = active component, 0 = retired/decommissioned. |
| doc_page_id | varchar(30) | Yes | — | Unique page identifier used by the documentation pipeline to derive filenames, build navigation, and link consumers to pages. NULL for components without documentation pages. Multiple components can share the same doc_page_id when they contribute sections to the same page. |
| doc_title | varchar(100) | Yes | — | Display title for the page — used in site navigation, Hub card grid, and published documentation. Only populated on the primary row for each page (the row with doc_sort_order set). NULL for secondary rows on multi-component pages and for components without documentation pages. |
| doc_json_schema | varchar(100) | Yes | — | Schema name(s) for the JSON DDL reference data consumed by the reference page. Comma-separated when multiple schemas contribute. Maps to JSON filenames in the documentation data directory. NULL when the component does not contribute objects to a reference page. |
| doc_json_categories | varchar(200) | Yes | — | Category filter(s) applied when the component uses only a subset of a schema's objects on the reference page. Comma-separated. Filters the JSON data by the category field in Object_Metadata. NULL when no filtering is needed or no reference page contribution exists. |
| doc_cc_slug | varchar(50) | Yes | — | Named CC guide page slug. When populated, this component has a dedicated CC guide page at {pageId}-cc-{slug}.html in the cc/ subfolder. The doc_title on this same row provides the nav label. When NULL, the standard single-file convention {pageId}-cc.html applies. Only activates when at least one section row for the pageId has a slug — backward compatible with all existing single-CC-guide pages. |
| doc_sort_order | int | Yes | — | Display order for page position in navigation and the index card grid. Lower values appear first. Uses increments of 10 for easy insertion of new pages. A value of 0 identifies the index page (site root). Only populated on the primary row for each page. NULL for secondary rows and components without documentation pages. |
| doc_section_order | int | Yes | — | Display order for this component's section within a multi-component reference page. Controls the sequence of schema sections in the reference page navigation. For single-component pages, this is 1. NULL for the Hub and components without documentation pages. |
| created_dttm | datetime | No | getdate() | When this component was registered. Auto-populated via default. |
| created_by | varchar(100) | No | suser_sname() | Who registered this component. Auto-populated via SUSER_SNAME() default. |

  - **PK_Component_Registry** (CLUSTERED): component_id -- PRIMARY KEY
  - **UQ_Component_Registry_cc_prefix** (NONCLUSTERED): cc_prefix
  - **UQ_Component_Registry_component_name** (NONCLUSTERED): component_name

**Check Constraints:**

  - **CK_Component_Registry_cc_prefix**: `([cc_prefix] IS NULL OR ([cc_prefix]) collate SQL_Latin1_General_CP1_CS_AS like '[a-z][a-z0-9][a-z]')`

**Foreign Keys:**

  - **FK_Component_Registry_Module**: module_name -> dbo.Module_Registry.module_name

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| is_active | 1 | Component is active and in use. Default value on INSERT. | 1 |
| is_active | 0 | Component has been retired or decommissioned. Objects may still exist in Object_Registry for historical reference. | 2 |

**All active components by module** [sort:1] -- Lists all registered components grouped by module.

```sql
SELECT module_name, component_name, description
FROM dbo.Component_Registry
WHERE is_active = 1
ORDER BY module_name, component_name;
```

**Components with their object counts by category** [sort:2] -- Shows each component with a breakdown of how many objects it contains per category.

```sql
SELECT
    cr.component_name,
    SUM(CASE WHEN oreg.object_category = 'Database' THEN 1 ELSE 0 END) AS db_objects,
    SUM(CASE WHEN oreg.object_category = 'PowerShell' THEN 1 ELSE 0 END) AS ps_scripts,
    SUM(CASE WHEN oreg.object_category = 'WebAsset' THEN 1 ELSE 0 END) AS web_assets,
    SUM(CASE WHEN oreg.object_category = 'Documentation' THEN 1 ELSE 0 END) AS doc_files,
    COUNT(oreg.registry_id) AS total
FROM dbo.Component_Registry cr
LEFT JOIN dbo.Object_Registry oreg
    ON oreg.component_name = cr.component_name AND oreg.is_active = 1
WHERE cr.is_active = 1
GROUP BY cr.component_name
ORDER BY cr.component_name;
```

  - **Object_Registry**: [sort:1] Object_Registry has a foreign key to Component_Registry on component_name. Every object in the platform is linked to exactly one component through this relationship.
  - **System_Metadata**: [sort:2] System_Metadata has a foreign key to Component_Registry on component_name. Version history entries are recorded against the component, not individual objects.


### Credentials

Secure credential storage table containing encrypted configuration values for external service authentication. Used by PowerShell scripts and procedures to retrieve API keys, tokens, and connection strings without hardcoding sensitive data.

**Data Flow:** Rows are manually inserted with encrypted VARBINARY values using application-layer encryption with a two-tier passphrase model (master passphrase decrypts a service-specific passphrase, which decrypts individual credential values). PowerShell scripts query at runtime to retrieve API tokens, usernames, and passwords for external service integrations (Jira, Teams, SFTP) without hardcoding sensitive data. Decryption occurs in the consuming script, not at the database level.

**Two-Tier Encryption Model:** [sort:1] Credentials use ENCRYPTBYPASSPHRASE with a two-tier key hierarchy: a master passphrase decrypts a service-specific passphrase stored as a ConfigKey = 'Passphrase' row, which in turn decrypts the actual credential values (Username, Password, ApiToken). This provides key rotation at the service level without re-encrypting all credentials.

**Composite Primary Key with Environment:** [sort:2] The three-column composite key (Environment, ServiceName, ConfigKey) allows the same service to have different credentials for DEV, TEST, and PROD environments in a single table. Scripts filter by Environment = 'PROD' at query time.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| Environment | varchar(20) | No | — | Environment identifier (DEV, TEST, PROD) |
| ServiceName | varchar(50) | No | — | Service this credential belongs to (FK to CredentialServices) |
| ConfigKey | varchar(50) | No | — | Specific credential key (e.g., ApiToken, Username, Password) |
| ConfigValue | varbinary(MAX) | No | — | Encrypted credential value stored as VARBINARY. Decrypted at runtime by consuming PowerShell scripts using the two-tier passphrase model. Contains API keys, tokens, passwords, or connection strings depending on the ConfigKey. |
| CreatedDate | datetime | Yes | getdate() | When the credential was created |
| ModifiedDate | datetime | Yes | — | When the credential was last updated |

  - **PK_Credentials** (CLUSTERED): Environment, ServiceName, ConfigKey -- PRIMARY KEY

**Foreign Keys:**

  - **FK_Credentials_ServiceName**: ServiceName -> dbo.CredentialServices.ServiceName

  - **CredentialServices**: [sort:1] Child table. ServiceName references CredentialServices.ServiceName. CredentialServices defines the catalog of valid services; Credentials stores the actual encrypted values per environment.
  - **FileOps.ServerConfig**: [sort:2] FileOps.ServerConfig.credential_service_name references the same ServiceName values, linking SFTP server configurations to their authentication credentials.


### CredentialServices

Reference table defining external services that require stored credentials. Provides metadata about each service type and serves as the parent lookup for the Credentials table.

**Data Flow:** Rows are manually inserted when a new external service integration is established. Serves as the parent lookup table for Credentials, enforcing valid ServiceName values through referential integrity. The ServiceType column categorizes integrations for reporting (API, Webhook, Database, FileShare, Email).

**Service Catalog Purpose:** [sort:1] This table centralizes the list of all external integrations in one place, making it easy to understand the platform's integration footprint. Deactivating a service here (Is_Active = 0) does not automatically prevent credential retrieval but signals that the integration should not be used.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| ServiceName | varchar(50) | No | — | Unique identifier for the service (e.g., JiraAPI, TeamsWebhook) |
| ServiceType | varchar(20) | No | — | Category of external integration. Classifies services for reporting and grouping: API, Webhook, Database, FileShare, Email. |
| Description | varchar(500) | Yes | — | Human-readable description of the service purpose |
| Is_Active | bit | No | 1 | Whether credentials for this service should be used |
| Created_Date | datetime | No | getdate() | When the service was registered |

  - **PK_CredentialServices** (CLUSTERED): ServiceName -- PRIMARY KEY

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| ServiceType | API | REST or SOAP API integration (e.g., JiraAPI, ServiceNow). | 1 |
| ServiceType | Webhook | Outbound webhook notification targets (e.g., TeamsWebhook). | 2 |
| ServiceType | Database | External database connections (e.g., LinkedServer, Oracle). | 3 |
| ServiceType | FileShare | Network file share or SFTP access (e.g., SFTPServer). | 4 |
| ServiceType | Email | Email service credentials (e.g., SMTPRelay, Office365). | 5 |

  - **Credentials**: [sort:1] Parent table. Credentials.ServiceName references CredentialServices.ServiceName. Each service can have multiple credential rows (one per Environment + ConfigKey combination).


### DatabaseRegistry

Registry of databases enrolled in xFACts operations, linking databases to their host servers. This is a shared infrastructure table providing database identification for all modules.

**Data Flow:** Rows are manually inserted when enrolling a database for xFACts operations. The server_id foreign key links to ServerRegistry. Monitoring scripts query this table joined to ServerRegistry to determine which databases to process. Module-specific configuration tables (e.g., ServerOps.DatabaseConfig) link via database_id for component settings like backup, index maintenance, and statistics preferences.

**Identity Only Design:** [sort:1] This table contains only identification and server linkage. Component-specific settings live in dedicated configuration tables (ServerOps.DatabaseConfig, etc.), keeping the shared registry focused on identity. This separation was created when the original ServerOps.DatabaseRegistry was split during the dbo schema refactoring.

**Explicit Enrollment:** [sort:2] Databases must be explicitly enrolled rather than auto-discovered. This prevents accidental operations on vendor databases or systems not ready for automated management.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| database_id (IDENTITY) | int | No | IDENTITY | Unique identifier for the database enrollment |
| server_id | int | No | — | FK to ServerRegistry.server_id |
| database_name | varchar(128) | No | — | Database name as it appears in sys.databases |
| is_active | bit | No | 1 | Whether this enrollment is active |
| created_dttm | datetime | No | getdate() | When the enrollment was created |
| created_by | varchar(100) | No | suser_sname() | Who created the enrollment |
| modified_dttm | datetime | Yes | — | When the enrollment was last modified |
| modified_by | varchar(100) | Yes | — | Who last modified the enrollment |

  - **PK_DatabaseRegistry** (CLUSTERED): database_id -- PRIMARY KEY
  - **IX_DatabaseRegistry_ServerId** (NONCLUSTERED): server_id, is_active [includes: database_name]
  - **UQ_DatabaseRegistry_ServerDatabase** (NONCLUSTERED): server_id, database_name

**Foreign Keys:**

  - **FK_DatabaseRegistry_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**All enrolled databases with server info** [sort:1] -- Shows all active database enrollments joined to their host server.

```sql
SELECT d.database_id, d.database_name, s.server_name, s.environment,
       d.is_active, d.notes
FROM dbo.DatabaseRegistry d
JOIN dbo.ServerRegistry s ON s.server_id = d.server_id
WHERE d.is_active = 1
ORDER BY s.server_name, d.database_name;
```

  - **ServerRegistry**: [sort:1] Child table. server_id references ServerRegistry.server_id. Each database belongs to exactly one server.
  - **ServerOps.DatabaseConfig**: [sort:2] One-to-one extension. ServerOps.DatabaseConfig.database_id references DatabaseRegistry.database_id for component-specific settings (backup, index, statistics configuration).


### GlobalConfig

Consolidated key-value configuration table for all xFACts modules. Stores settings that control component behavior, thresholds, paths, and operational parameters.

**Data Flow:** Rows are manually inserted or updated when configuring module behavior. Every PowerShell monitoring script and the Control Center read settings at startup or per-cycle using module_name and setting_name lookups. The Control Center GlobalConfig editor page provides a UI for modifying values, with every change logged to dbo.ActionAuditLog as entity_type = 'GlobalConfig'. The is_ui_editable flag controls which settings appear in the editor.

**Consolidation from Module-Specific Tables:** [sort:1] GlobalConfig replaced four separate configuration tables (ServerOps.Activity_Config, Backup_Config, Disk_Config, Maintenance_Config) during the dbo schema refactoring. The consolidated design provides a single query pattern across all modules while module_name and category maintain logical separation.

**String Storage with Type Hint:** [sort:2] All values are stored as VARCHAR in setting_value with a data_type column (INT, DECIMAL, BIT, VARCHAR) indicating how to interpret the value. Consuming code is responsible for casting. This avoids multiple typed columns while preserving type intent for the Control Center editor.

**UI Editability Control:** [sort:3] The is_ui_editable flag determines which settings appear in the Control Center GlobalConfig editor. Settings that should only be changed with direct database access (e.g., structural configuration) can be hidden from the UI while remaining queryable by scripts.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| config_id (IDENTITY) | int | No | IDENTITY | Unique identifier for the setting |
| module_name | varchar(50) | No | — | Module that owns this setting (ServerOps, dbo, JobFlow, etc.) |
| setting_name | varchar(100) | No | — | Setting identifier (must be unique within module) |
| setting_value | varchar(500) | No | — | The configuration value (stored as string) |
| data_type | varchar(20) | No | — | How to interpret the value: INT, DECIMAL, BIT, VARCHAR |
| category | varchar(50) | Yes | — | Component within module (Index, Backup, Activity_XE, Activity_DMV, Disk) |
| is_active | bit | No | 1 | Whether this setting is currently in effect |
| description | varchar(500) | No | — | What this setting controls |
| is_ui_editable | bit | No | 1 | Determines whether config is available for editing in Control Center UI |
| notes | varchar(500) | Yes | — | Additional context or reason for current value |
| created_dttm | datetime | No | getdate() | When the setting was created |
| created_by | varchar(100) | No | suser_sname() | Who created the setting |

  - **PK_GlobalConfig** (CLUSTERED): config_id -- PRIMARY KEY
  - **UQ_GlobalConfig_setting** (NONCLUSTERED): module_name, category, setting_name

**All settings for a module** [sort:1] -- Shows all active configuration for a specific module with category grouping.

```sql
SELECT setting_name, setting_value, data_type, category, description
FROM dbo.GlobalConfig
WHERE module_name = 'ServerOps'
  AND is_active = 1
ORDER BY category, setting_name;
```

**Search for a setting by keyword** [sort:2] -- Finds settings across all modules matching a keyword pattern.

```sql
SELECT module_name, category, setting_name, setting_value, description
FROM dbo.GlobalConfig
WHERE setting_name LIKE '%threshold%'
  AND is_active = 1
ORDER BY module_name, setting_name;
```

**UI-editable settings** [sort:3] -- Shows settings available for editing in the Control Center.

```sql
SELECT module_name, category, setting_name, setting_value, data_type, description
FROM dbo.GlobalConfig
WHERE is_ui_editable = 1
  AND is_active = 1
ORDER BY module_name, category, setting_name;
```

  - **ActionAuditLog**: [sort:1] Every Control Center edit to a GlobalConfig setting generates an ActionAuditLog row with entity_type = 'GlobalConfig' and entity_name = the setting_name, capturing old_value and new_value for audit trail.
  - **ProcessRegistry**: [sort:2] The orchestrator engine reads heartbeat_interval_seconds and orchestrator_drain_mode from GlobalConfig on every cycle. Multiple module scripts read their own settings at startup.


### Holiday

Calendar of company holiday dates used by scheduling components across xFACts modules. Contains the list of recognized holidays; actual schedule behaviors are defined in module-specific tables.

**Data Flow:** Populated via sp_GenerateHolidays for standard annual US holidays (fixed and floating) or sp_AddHoliday for individual company-specific entries. Both procedures apply weekend observation rules (Saturday to Friday, Sunday to Monday). Scheduling-aware modules query this table to determine if the current date is a holiday. Currently consumed by the ServerOps Index component via ServerOps.HolidaySchedule for maintenance window determination.

**Date as Primary Key:** [sort:1] The holiday_date column is the primary key. Each calendar date can appear at most once, preventing duplicate entries. This means the observed date is stored, not the actual holiday date when they differ due to weekend observation.

**Calendar Only — No Schedule Behavior:** [sort:2] This table contains only the holiday calendar. How each module behaves on holidays is defined in module-specific tables (e.g., ServerOps.HolidaySchedule). This separation allows different modules to react differently to the same holiday.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| holiday_date | date | No | — | Calendar date of the holiday (use observed date for weekend holidays) |
| holiday_name | varchar(50) | No | — | Display name (e.g., "Christmas Day", "Thanksgiving", "Memorial Day") |
| is_active | bit | No | 1 | Whether this holiday is currently recognized for scheduling purposes |
| created_dttm | datetime | No | getdate() | When this holiday was added |
| created_by | varchar(100) | No | suser_sname() | Who added this holiday |

  - **PK_Holiday** (CLUSTERED): holiday_date -- PRIMARY KEY

**Upcoming holidays** [sort:1] -- Shows the next 12 months of active holidays.

```sql
SELECT holiday_date, DATENAME(WEEKDAY, holiday_date) AS day_of_week, holiday_name
FROM dbo.Holiday
WHERE holiday_date BETWEEN GETDATE() AND DATEADD(YEAR, 1, GETDATE())
  AND is_active = 1
ORDER BY holiday_date;
```

**Check if today is a holiday** [sort:2] -- Quick check used by scheduling logic.

```sql
SELECT holiday_name
FROM dbo.Holiday
WHERE holiday_date = CAST(GETDATE() AS DATE)
  AND is_active = 1;
```

  - **sp_GenerateHolidays**: [sort:1] Bulk population procedure that calculates and inserts standard US holidays for a given year, including floating holidays (Memorial Day, Thanksgiving) and weekend observation shifts.
  - **sp_AddHoliday**: [sort:2] Single-holiday insertion procedure for company-specific holidays or one-off closures not covered by the annual generation.
  - **ServerOps.HolidaySchedule**: [sort:3] Defines per-database maintenance window behavior on holidays. References Holiday dates to determine whether index maintenance should run, and with what time window, on each holiday.


### Module_Registry

Top-level module definitions for the xFACts platform. Each module represents a functional domain (ServerOps, JobFlow, Teams, etc.). Completes the three-tier hierarchy: Module_Registry ? Component_Registry ? Object_Registry. The description column holds a brief business-friendly tagline displayed in the Control Center admin panel.

**Data Flow:** Rows are inserted when new functional modules are established. Referenced by Component_Registry, Object_Registry, and System_Metadata via FK on module_name. The Admin page System Metadata modal reads Module_Registry to display module taglines on the tree header rows.

**Three-tier hierarchy:** [sort:1] Module_Registry defines the top-level functional domains. Component_Registry groups related objects within a module. Object_Registry catalogs individual assets. System_Metadata tracks version history at the component level. module_name is the natural join key across all four tables.

**Tagline brevity constraint:** [sort:2] The description is displayed inline on the module header row in the admin panel, filling the visual gap between the module name and the component/object counts. Longer descriptions would wrap or truncate. The 8-words-or-less guideline keeps taglines scannable at a glance.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| module_id (IDENTITY) | int | No | IDENTITY | Auto-incrementing primary key. |
| module_name | varchar(50) | No | — | Unique module identifier matching schema names where applicable: dbo, ServerOps, JobFlow, BatchOps, BIDATA, FileOps, Teams, Jira, Orchestrator, ControlCenter, DeptOps. |
| description | varchar(100) | No | — | Business-friendly tagline, 8 words or less. Displayed on the module header row in the System Metadata admin panel. |
| is_active | bit | No | 1 | Soft delete flag. 1 = active module, 0 = retired. |
| created_dttm | datetime | No | getdate() | When this module was registered. Auto-populated via default. |
| created_by | varchar(100) | No | suser_sname() | Who registered this module. Auto-populated via SUSER_SNAME() default. |

  - **PK_Module_Registry** (CLUSTERED): module_id -- PRIMARY KEY
  - **UQ_Module_Registry_module_name** (NONCLUSTERED): module_name

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| is_active | 1 | Module is active. Default value on INSERT. | 1 |
| is_active | 0 | Module has been retired or decommissioned. | 2 |

**All active modules** [sort:1] -- Lists all registered modules with their taglines.

```sql
SELECT module_name, description
FROM dbo.Module_Registry
WHERE is_active = 1
ORDER BY module_name;
```

  - **Component_Registry**: [sort:1] Component_Registry has a foreign key to Module_Registry on module_name. Every component must belong to a registered module.
  - **Object_Registry**: [sort:2] Object_Registry has a foreign key to Module_Registry on module_name. Provides direct module lookup without joining through Component_Registry.
  - **System_Metadata**: [sort:3] System_Metadata has a foreign key to Module_Registry on module_name. Version entries reference the module for grouping in the admin tree.


### Object_Metadata

Single source of truth for all documentation metadata about database objects across the xFACts platform. Replaces extended properties as the documentation content source. Fed into the DDL JSON export by the DDL reference generator, rendered automatically on reference and troubleshooting pages.

**Data Flow:** Populated manually via INSERT/UPDATE during object creation and documentation maintenance. Read by the DDL reference generator during JSON export to produce schema-level DDL JSON files. Those JSON files are consumed by the reference and troubleshooting pages in the Control Center documentation site.

**Single Source for All Documentation Content:** [sort:1] All documentation metadata lives in this table — object descriptions, column descriptions, design rationale, operational queries, status definitions, and relationship context. Extended properties (MS_Description) are no longer used. One system, one place to look, one way to update.

**Graceful Degradation:** [sort:2] The DDL export still reads structural metadata (columns, types, constraints, indexes, FKs) from system catalog views. Object_Metadata provides the documentation layer on top. If a column lacks a description row here, it still appears on the reference page with its structural info — just without commentary. Incomplete is better than incorrect.

**Soft Delete Over Hard Delete:** [sort:3] Rows are deactivated via is_active = 0 rather than deleted. This preserves audit trail and allows reactivation if content is retired prematurely.

**Duplicate Prevention:** [sort:4] A unique filtered index (UX_Object_Metadata_NaturalKey) enforces one active row per natural key combination: schema_name, object_name, object_type, column_name_key, property_type, and sort_order. Scoped to is_active = 1 so deactivated rows do not block new inserts. The column_name_key computed column converts NULL to empty string for clean index behavior since column_name is NULL for object-level rows but populated for column-level rows.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| metadata_id (IDENTITY) | int | No | IDENTITY | Unique identifier for each metadata row |
| schema_name | varchar(128) | No | — | Schema the documented object belongs to: dbo, ServerOps, JobFlow, BatchOps, etc. |
| object_name | varchar(128) | No | — | Name of the documented object: table name, procedure name, script filename, etc. |
| object_type | varchar(50) | No | — | Kind of object: Table, Procedure, Trigger, DDL Trigger, XE Session, Script |
| column_name | varchar(128) | Yes | — | NULL for object-level properties. Populated for column-level descriptions and status values scoped to specific columns. For status values applying to multiple columns, use comma-separated column names. |
| property_type | varchar(50) | No | — | What kind of documentation content this row holds. Controls how the export proc and loader handle the row. |
| sort_order | int | No | 0 | Display ordering within a property type for a given object. 0-based. Column descriptions use ordinal position. Design notes, queries, and status values use logical sequence. |
| title | varchar(200) | Yes | — | Context-dependent label. Query name for queries, topic name for design notes, status value string for status_value rows. NULL for types that do not need a label (description, data_flow, module, category). |
| description | varchar(500) | Yes | — | Optional short explanation providing context for the content. Used for queries (what the query shows) and design notes (brief summary). NULL when content is self-explanatory. |
| content | varchar(MAX) | No | — | The actual documentation content. A description paragraph, a full SQL query, a status value meaning, a data flow narrative. Content type is determined by property_type. |
| is_active | bit | No | 1 | Soft delete flag. Inactive rows are excluded from JSON export. Use this instead of DELETE to preserve audit trail. |
| created_dttm | datetime | No | getdate() | When the row was created |
| created_by | varchar(100) | No | suser_sname() | Who created the row (auto-populated from login) |
| modified_dttm | datetime | No | getdate() | When the row was last updated |
| modified_by | varchar(100) | No | suser_sname() | Who last updated the row (auto-populated from login) |
| column_name_key | varchar(128) | No | — | Persisted computed column: ISNULL(column_name, ''). Provides NULL-safe indexing for the unique filtered index UX_Object_Metadata_NaturalKey. |

  - **PK_Object_Metadata** (CLUSTERED): metadata_id -- PRIMARY KEY
  - **IX_Object_Metadata_PropertyType** (NONCLUSTERED): property_type, schema_name [includes: object_name, title, is_active]
  - **IX_Object_Metadata_SchemaObject** (NONCLUSTERED): schema_name, object_name, property_type [includes: column_name, sort_order, title, is_active]
  - **UX_Object_Metadata_NaturalKey** (NONCLUSTERED): schema_name, object_name, object_type, column_name_key, property_type, sort_order

**Check Constraints:**

  - **CK_Object_Metadata_ObjectType**: `([object_type]='DDL Trigger' OR [object_type]='XE Session' OR [object_type]='Script' OR [object_type]='View' OR [object_type]='Function' OR [object_type]='Trigger' OR [object_type]='Procedure' OR [object_type]='Table')`
  - **CK_Object_Metadata_PropertyType**: `([property_type]='relationship_note' OR [property_type]='status_value' OR [property_type]='query' OR [property_type]='design_note' OR [property_type]='data_flow' OR [property_type]='category' OR [property_type]='module' OR [property_type]='description')`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| property_type | description | Object or column description. When column_name is NULL, describes the object. When column_name is populated, describes that specific column. | 1 |
| property_type | module | Which module owns this object. Values match schema names: dbo, ServerOps, JobFlow, BatchOps, BIDATA, FileOps, Teams, Jira, Orchestrator, DeptOps. | 2 |
| property_type | category | Functional grouping within a module. Examples: Backup, Index, Activity_XE, Activity_DMV, Disk, Replication for ServerOps. Shared Infrastructure, RBAC for dbo. | 3 |
| property_type | data_flow | Paragraph describing how data enters, moves through, and exits this object. Names the scripts that write to it, the processes that read from it, and what the Control Center displays from it. | 4 |
| property_type | design_note | Explanation of a non-obvious architectural or design decision. Title holds the topic name. Content holds the rationale. | 5 |
| property_type | query | Common operational query. Title holds the query name. Description holds what the query shows or when to use it. Content holds the full copy-paste-ready SQL. | 6 |
| property_type | status_value | Definition of a valid status or type value for a check-constrained column. Title holds the value itself. Column_name identifies which column(s) it applies to. Content holds what the value means and when it is set. | 7 |
| property_type | relationship_note | Cross-object relationship context that foreign key metadata alone does not convey. Title holds the related object name. Content explains the operational relationship. | 8 |

**All metadata for a specific object** [sort:1] -- View everything documented about a single table, procedure, or script.

```sql
SELECT property_type, column_name, sort_order, title, description, content
FROM dbo.Object_Metadata
WHERE schema_name = 'ServerOps'
  AND object_name = 'Backup_FileTracking'
  AND is_active = 1
ORDER BY property_type, sort_order;
```

**Objects missing column descriptions** [sort:2] -- Find columns that exist in the database but have no description row in Object_Metadata.

```sql
SELECT s.name AS schema_name, t.name AS table_name, c.name AS column_name
FROM sys.columns c
INNER JOIN sys.tables t ON t.object_id = c.object_id
INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name IN ('dbo','ServerOps','JobFlow','BatchOps','BIDATA','FileOps','Teams','Jira','Orchestrator','DeptOps')
  AND NOT EXISTS (
      SELECT 1 FROM dbo.Object_Metadata om
      WHERE om.schema_name = s.name
        AND om.object_name = t.name
        AND om.column_name = c.name
        AND om.property_type = 'description'
        AND om.is_active = 1
  )
ORDER BY s.name, t.name, c.column_id;
```

**Documentation coverage by module** [sort:3] -- Summary of how many objects and columns have descriptions per schema.

```sql
SELECT om.schema_name,
       COUNT(DISTINCT CASE WHEN om.column_name IS NULL AND om.property_type = 'description' THEN om.object_name END) AS objects_documented,
       COUNT(CASE WHEN om.column_name IS NOT NULL AND om.property_type = 'description' THEN 1 END) AS columns_documented,
       COUNT(DISTINCT CASE WHEN om.property_type = 'query' THEN om.object_name END) AS objects_with_queries,
       COUNT(DISTINCT CASE WHEN om.property_type = 'design_note' THEN om.object_name END) AS objects_with_design_notes
FROM dbo.Object_Metadata om
WHERE om.is_active = 1
GROUP BY om.schema_name
ORDER BY om.schema_name;
```


### Object_Registry

Complete asset inventory of every object in the xFACts platform. Each row represents an individual database object, PowerShell script, Control Center file, or documentation asset, linked to its parent component via component_name. Serves as the definitive catalog of what exists and where it lives.

**Data Flow:** Rows are inserted when new objects are created during platform development. Bulk-seeded during the versioning rearchitecture with all existing platform objects. The Admin page System Metadata modal reads Object_Registry to show the object catalog for each component. Future potential: documentation pipeline and file consolidation scripts could use object_path as a source-of-truth for file locations.

**Object category and type hierarchy:** [sort:1] object_category provides broad grouping (Database, PowerShell, WebAsset, Documentation) for high-level filtering. object_type provides specific classification (Table, Procedure, Script, Route, API, JavaScript, CSS, HTML, etc.) for detailed inventory queries. Both are constrained via CHECK constraints to prevent freeform values.

**object_path as source of truth:** [sort:2] Database objects store their schema name in object_path (dbo, ServerOps, etc.). Files store their full filesystem path. This makes Object_Registry the single source of truth for where any object lives, enabling future automation of documentation publishing, file consolidation, and deployment scripts that currently hardcode paths.

**Shared objects across components:** [sort:3] Some objects logically participate in multiple components (e.g., Collect-ServerHealth.ps1 serves both ServerOps.ServerHealth and ServerOps.Disk, Send-DiskHealthSummary.ps1 similarly). Each object has one row in Object_Registry linked to its primary component. The description field can note shared usage. This avoids duplication while maintaining a clean one-to-one object-to-component mapping.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| registry_id (IDENTITY) | int | No | IDENTITY | Auto-incrementing primary key. |
| module_name | varchar(50) | No | — | Functional module this object belongs to: dbo, ServerOps, JobFlow, BatchOps, BIDATA, FileOps, Teams, Jira, Orchestrator, ControlCenter, DeptOps. |
| component_name | varchar(128) | No | — | Parent component this object belongs to. FK to Component_Registry.component_name. |
| object_name | varchar(256) | No | — | Name of the individual object. Database objects use their bare SQL name without schema prefix; file components use their filename with extension. |
| object_category | varchar(50) | No | — | Broad classification: Database, PowerShell, WebAsset, Documentation. |
| object_type | varchar(50) | No | — | Specific object type within its category: Table, Procedure, Trigger, View, Function, Script, Route, API, Module, JavaScript, CSS, HTML. |
| object_path | varchar(500) | Yes | — | Where to find this object. Schema name for database objects (e.g., dbo, ServerOps). Full filesystem path for files (e.g., E:\xFACts\scripts\collectors\Collect-DMVMetrics.ps1). |
| description | varchar(500) | Yes | — | Brief description of what this object does. |
| zone | varchar(20) | Yes | — | The resolution universe a source file belongs to: cc, docs, standalone, or exempt; NULL for database objects. |
| scope | varchar(20) | Yes | — | Whether a source file's content is LOCAL to the file or SHARED across its zone; NULL for database objects. |
| scope_tier | varchar(20) | Yes | — | Identifies whether a shared scope chrome object is a platform wide resource or if it is scoped to a module. This determines the file's spec requirements. |
| is_active | bit | No | 1 | Soft delete flag. 1 = active, 0 = retired/dropped. |
| created_dttm | datetime | No | getdate() | When this object was registered. Auto-populated via default. |
| created_by | varchar(100) | No | suser_sname() | Who registered this object. Auto-populated via SUSER_SNAME() default. |

  - **PK_Object_Registry** (CLUSTERED): registry_id -- PRIMARY KEY
  - **IX_Object_Registry_component** (NONCLUSTERED): component_name [includes: object_name, object_category, object_type, is_active]
  - **IX_Object_Registry_module** (NONCLUSTERED): module_name [includes: component_name, object_name, object_category, object_type]
  - **UQ_Object_Registry_object** (NONCLUSTERED): component_name, object_name

**Check Constraints:**

  - **CK_Object_Registry_category**: `([object_category]='Documentation' OR [object_category]='WebAsset' OR [object_category]='PowerShell' OR [object_category]='Database')`
  - **CK_Object_Registry_scope**: `([scope]='exempt' OR [scope]='SHARED' OR [scope]='LOCAL')`
  - **CK_Object_Registry_scope_tier**: `([scope_tier]='SCOPED' OR [scope_tier]='PLATFORM' OR [scope_tier]='SHELL' OR [scope_tier]='BOOTSTRAP')`
  - **CK_Object_Registry_type**: `([object_type]='Config' OR [object_type]='Table' OR [object_type]='Procedure' OR [object_type]='Trigger' OR [object_type]='View' OR [object_type]='Function' OR [object_type]='Script' OR [object_type]='Route' OR [object_type]='API' OR [object_type]='Module' OR [object_type]='JavaScript' OR [object_type]='CSS' OR [object_type]='HTML' OR [object_type]='XE Session' OR [object_type]='DDL Trigger')`
  - **CK_Object_Registry_zone**: `([zone]='exempt' OR [zone]='standalone' OR [zone]='docs' OR [zone]='cc')`
  - **CK_Object_Registry_zone_scope_pairing**: `(([zone]='standalone' OR [zone]='docs' OR [zone]='cc') AND ([scope]='SHARED' OR [scope]='LOCAL') OR [zone]='exempt' AND [scope]='exempt' OR [zone] IS NULL AND [scope] IS NULL)`

**Foreign Keys:**

  - **FK_Object_Registry_Component**: component_name -> dbo.Component_Registry.component_name
  - **FK_Object_Registry_Module**: module_name -> dbo.Module_Registry.module_name

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| is_active | 1 | Object is active and in use. Default value on INSERT. | 1 |
| is_active | 0 | Object has been retired, dropped, or decommissioned. Row preserved for historical reference. | 2 |
| object_category | Database | SQL Server objects: tables, procedures, triggers, views, functions. | 1 |
| object_category | PowerShell | PowerShell scripts (.ps1) and modules (.psm1) in the automation layer. | 2 |
| object_category | WebAsset | Control Center files: route pages, API endpoints, JavaScript, CSS. | 3 |
| object_category | Documentation | Documentation site files: HTML pages, doc-specific JS and CSS. | 4 |

**All objects for a component** [sort:1] -- Lists every registered object within a specific component.

```sql
SELECT object_name, object_category, object_type, object_path, description
FROM dbo.Object_Registry
WHERE component_name = 'ServerOps.Index'
  AND is_active = 1
ORDER BY object_category, object_type, object_name;
```

**Platform inventory by category and type** [sort:2] -- Full breakdown of all active objects across the platform.

```sql
SELECT object_category, object_type, COUNT(*) AS [count]
FROM dbo.Object_Registry
WHERE is_active = 1
GROUP BY object_category, object_type
ORDER BY object_category, object_type;
```

**Find an object across the platform** [sort:3] -- Search for an object by partial name match. Useful for finding which component owns a particular script or table.

```sql
SELECT component_name, object_name, object_category, object_type, object_path
FROM dbo.Object_Registry
WHERE object_name LIKE '%BackupStatus%'
  AND is_active = 1;
```

**Objects with file paths for a module** [sort:4] -- Lists all file-based objects (scripts, CC files, docs) with their paths for a given module. Useful for deployment and consolidation scripts.

```sql
SELECT component_name, object_name, object_type, object_path
FROM dbo.Object_Registry
WHERE module_name = 'ServerOps'
  AND object_category != 'Database'
  AND is_active = 1
ORDER BY component_name, object_type, object_name;
```

  - **Component_Registry**: [sort:1] Object_Registry has a foreign key to Component_Registry on component_name. Every object must belong to a registered component.
  - **Object_Metadata**: [sort:2] Database objects in Object_Registry should have corresponding Object_Metadata entries for documentation. The object_name and schema (from object_path) map to Object_Metadata.object_name and schema_name respectively.


### Protection_ViolationLog

Audit table capturing all blocked DDL operations on protected xFACts objects. When the protection trigger prevents a DROP or ALTER operation, the attempted action is logged here for security review.

**Data Flow:** Populated by TR_xFACts_ProtectCriticalObjects via an autonomous transaction through the xFACts_Loopback linked server. When a protected DDL operation is intercepted, the trigger calls sp_LogProtectionViolation through the loopback, which runs in a separate transaction. This ensures the violation is logged even though the trigger then issues a ROLLBACK of the original DDL statement. Rows are append-only.

**Autonomous Transaction via Loopback:** [sort:1] DDL triggers that ROLLBACK face a fundamental problem: any data modifications within the trigger are also rolled back. The loopback linked server pattern (calling sp_LogProtectionViolation via xFACts_Loopback) creates a separate database session. The INSERT commits independently, surviving the trigger's ROLLBACK of the offending DDL.

**Guaranteed Logging:** [sort:2] If the loopback logging fails for any reason, the trigger still blocks the DDL operation. Protection is never compromised by logging failures. The logging is best-effort but the protection is absolute.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| violation_id (IDENTITY) | int | No | IDENTITY | PK |
| violation_dttm | datetime | No | — | When the blocked DDL operation was attempted. Captured by the protection trigger at the moment of interception. |
| username | nvarchar(50) | No | — | Windows login of the user who attempted the blocked DDL operation. Captured from the DDL trigger event data. |
| object_name | nvarchar(200) | No | — | Name of the protected object targeted by the blocked DDL operation. Captured from the DDL trigger event data. |
| event_type | nvarchar(100) | No | — | Type of DDL operation that was blocked (e.g., DROP_TABLE, ALTER_TABLE, DROP_PROCEDURE). Captured from the DDL trigger event data. |
| sql_text | nvarchar(MAX) | Yes | — | Complete SQL statement that was blocked |

  - **PK__Protecti__8A989363051DDB51** (CLUSTERED): violation_id -- PRIMARY KEY

**Recent violations** [sort:1] -- Shows blocked DDL attempts within the last 7 days.

```sql
SELECT violation_id, violation_dttm, username, object_name,
       event_type, LEFT(sql_text, 200) AS sql_preview
FROM dbo.Protection_ViolationLog
WHERE violation_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY violation_dttm DESC;
```

**Violations by user** [sort:2] -- Summary of blocked operations per user for security review.

```sql
SELECT username, COUNT(*) AS violation_count,
       MIN(violation_dttm) AS first_violation,
       MAX(violation_dttm) AS last_violation
FROM dbo.Protection_ViolationLog
GROUP BY username
ORDER BY violation_count DESC;
```

  - **TR_xFACts_ProtectCriticalObjects**: [sort:1] Source. The DDL trigger intercepts protected operations and logs the attempt to this table before issuing ROLLBACK.
  - **sp_LogProtectionViolation**: [sort:2] The INSERT is performed by this procedure, called through the xFACts_Loopback linked server to ensure the log entry commits in a separate transaction from the rolled-back DDL.


### ServerRegistry

Registry of SQL Server instances managed by xFACts, including connection information and module-level feature flags. This is a shared infrastructure table used by multiple modules.

**Data Flow:** Rows are manually inserted when onboarding a new SQL Server instance to xFACts. Module feature flags are toggled as modules are enabled for each server. Collect-ServerHealth.ps1 updates last_service_start_dttm from sys.dm_os_sys_info on each collection cycle. Every monitoring script queries ServerRegistry to determine which servers to process based on module-specific feature flags (e.g., serverops_backup_enabled, serverops_maintenance_enabled). DatabaseRegistry references server_id as a foreign key.

**Module Feature Flags:** [sort:1] Each module has its own enable/disable bit column (serverops_activity_enabled, serverops_backup_enabled, serverops_disk_enabled, serverops_maintenance_enabled, jobflow_enabled, batchops_enabled, fileops_enabled, bidata_enabled). This allows servers to participate in some modules but not others based on their role. All flags default to 0 (disabled), requiring explicit enablement.

**AG Cluster Grouping:** [sort:2] The ag_cluster_name field groups servers that belong to the same Always On Availability Group. Both primary and secondary nodes are registered independently since either could hold the primary role at any time. Server ID 0 (AVG-PROD-LSNR) represents the AG listener endpoint, not a physical server.

**Service Start Time Context:** [sort:3] The last_service_start_dttm field captures when the SQL Server service last started, sourced from sys.dm_os_sys_info. This provides context for DMV-based statistics like index usage stats which reset on service restart.

**Environment-Based Activation Constraint:** [sort:4] CK_ServerRegistry_environment_is_active enforces that only PROD servers can be set to is_active = 1. Non-PROD servers (STAGE, TEST, DEV) are registered for reference by processes that need environment-specific targets but are permanently excluded from orchestrator-managed collection cycles. This prevents accidental enrollment of lower-environment servers in production monitoring.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| server_id (IDENTITY) | int | No | IDENTITY | Unique identifier for the server |
| server_name | varchar(128) | No | — | Server hostname (must match hostname for WinRM) |
| instance_name | varchar(128) | Yes | — | SQL Server instance name for named instances (NULL = default instance) |
| server_type | varchar(50) | No | 'SQL_SERVER' | Type of server (SQL_SERVER, WINDOWS, AG_LISTENER) |
| sql_edition | varchar(50) | Yes | — | SQL Server edition (Enterprise, Standard) - determines feature availability |
| environment | varchar(20) | No | 'PROD' | Server environment designation. Constrained to PROD, STAGE, TEST, or DEV. Only PROD servers can have is_active = 1 (enforced by CK_ServerRegistry_environment_is_active). |
| server_role | varchar(100) | Yes | — | Description of server's purpose/role |
| ag_cluster_name | varchar(128) | Yes | — | Availability Group name (NULL for standalone) |
| description | varchar(500) | Yes | — | Additional notes about the server |
| cpu_count | int | Yes | — | Number of logical CPU cores on the server. Used for CPU percentage calculations in DMV workload snapshots. |
| is_active | bit | No | 1 | Controls whether the server is enrolled in orchestrator-managed collection processes. Servers with is_active = 1 are actively monitored by automated collectors in the Orchestrator. Servers with is_active = 0 are registered for reference by other processes but excluded from automated collection. Constrained by CK_ServerRegistry_environment_is_active: only PROD servers can be set to 1. |
| serverops_activity_enabled | bit | No | 0 | Enable Extended Events and DMV collection (ServerOps Activity component) |
| serverops_backup_enabled | bit | No | 0 | Enable backup monitoring (ServerOps Backup component) |
| serverops_disk_enabled | bit | No | 1 | Enable disk space monitoring (ServerOps Disk component) |
| serverops_index_enabled | bit | No | 0 | Enable index maintenance (ServerOps Index component) |
| serverops_dbcc_enabled | bit | No | 0 | Enable DBCC CHECKDB execution for this server. When enabled, Execute-DBCC.ps1 processes all active databases from DatabaseRegistry on the day specified by dbcc_run_day. |
| jobflow_enabled | bit | No | 0 | Enable job monitoring (JobFlow module) |
| batchops_enabled | bit | No | 0 | Enable batch monitoring (BatchOps module) |
| fileops_enabled | bit | No | 0 | Enable file monitoring (FileOps module) |
| bidata_enabled | bit | No | 0 | Enable BI build monitoring (BIDATA module) |
| dmops_archive_enabled | bit | No | 0 | Whether DM archive processing is enabled for this server. Execute-DmArchive.ps1 checks this flag on the target server at startup. 0 = archive processing disabled, 1 = enabled. Independent of other module enable flags. |
| dmops_shell_purge_enabled | bit | No | 0 | Whether shell purge processing is enabled for this server. Execute-DmShellPurge.ps1 checks this flag at startup when running from GlobalConfig target_instance (skipped when TargetInstance parameter is specified manually). 1 = enabled, 0 = disabled. |
| jboss_enabled | bit | No | 0 | Enable JBoss application server monitoring for this server. When enabled, Collect-JBossMetrics.ps1 queries datasource pool metrics, undertow throughput, and deployment status via the JBoss Management API. |
| is_domain_controller | bit | No | 0 | Identifies the JBoss domain controller server. The DmOps metrics collector uses this flag to determine which server hosts the Management API endpoint. Only one server should have this set to 1. |
| jboss_ds_alert_threshold | int | No | 0 | Datasource connection pool alert threshold for JBoss monitoring. When ds_in_use_count equals or exceeds this value for two consecutive snapshots, a CRITICAL Teams alert fires. 0 = alerting disabled for this server. Each server can have an independent threshold to accommodate different workload profiles. |
| tools_enabled | bit | No | 0 | Enable Tools module operations for this server. When enabled, the server is available as a target for BDL imports, CDL imports, payment file processing, and other Tools-driven operations. Tools.ServerConfig provides per-server configuration details. 0 = disabled (default), 1 = enabled. |
| api_base_url | varchar(200) | Yes | — | DM REST API base URL for this server. Populated for APP_SERVER and STANDALONE entries that expose a DM REST API. NULL for SQL_SERVER and AG_LISTENER entries. Used by Tools operations for API call targeting. |
| is_api_primary | bit | No | 0 | Marks the default API target for single-server operations in this environment. One primary per environment. All-server operations (e.g., Refresh Drools) iterate all servers with api_base_url populated and tools_enabled = 1. |
| last_service_start_dttm | datetime | Yes | — | SQL Server service start time from sys.dm_os_sys_info |
| last_service_start_captured_dttm | datetime | Yes | — | When the service start time was last captured |
| created_dttm | datetime | No | getdate() | When server was registered |
| created_by | varchar(100) | No | suser_sname() | Who registered the server |
| modified_dttm | datetime | Yes | — | When record was last modified |
| modified_by | varchar(100) | Yes | — | Who last modified the record |

  - **PK_ServerRegistry** (CLUSTERED): server_id -- PRIMARY KEY
  - **IX_ServerRegistry_Active** (NONCLUSTERED): is_active, environment [includes: server_name, instance_name, ag_cluster_name]
  - **UQ_ServerRegistry_ServerName** (NONCLUSTERED): server_name

**Check Constraints:**

  - **CK_ServerRegistry_Environment**: `([environment]='PROD' OR [environment]='STAGE' OR [environment]='TEST' OR [environment]='DEV')`
  - **CK_ServerRegistry_environment_is_active**: `([environment]='PROD' OR [is_active]=(0))`
  - **CK_ServerRegistry_ServerType**: `([server_type]='APP_SERVER' OR [server_type]='AG_LISTENER' OR [server_type]='WINDOWS' OR [server_type]='SQL_SERVER' OR [server_type]='STANDALONE')`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| environment | PROD | Production environment. These servers can be set to is_active = 1 for orchestrator-managed collection. All automated monitoring runs exclusively against PROD servers. | 1 |
| environment | DEV | Development environment. Cannot be set to is_active = 1 (enforced by CHECK constraint). Available as a target for testing processes via environment-based lookups. | 2 |
| environment | TEST | Test environment. Cannot be set to is_active = 1 (enforced by CHECK constraint). Used by DmOps archive/shell purge testing and BDL Import testing via environment-based or GlobalConfig target_instance lookups. | 3 |
| environment | STAGE | Staging environment. Cannot be set to is_active = 1 (enforced by CHECK constraint). Represents the DM staging AG cluster (DM-STAGE-DB / DM-STAGE-REP / AVG-STAGE-LSNR) and associated app servers. | 4 |
| is_active | 1 | Server is actively enrolled in orchestrator-managed collection processes. Only PROD servers can have this value (enforced by CK_ServerRegistry_environment_is_active). All automated collectors filter on is_active = 1. | 1 |
| is_active | 0 | Server is registered but not enrolled in automated collection. Required for all non-PROD servers (STAGE, TEST, DEV). PROD servers may also be set to 0 to temporarily exclude them from collection without removing the registration. | 2 |
| server_type | SQL_SERVER | Standard SQL Server instance. Default value for new registrations. | 1 |
| server_type | WINDOWS | Windows server monitored for non-SQL operations (e.g., disk space only). | 2 |
| server_type | AG_LISTENER | Availability Group listener endpoint. Represents a logical connection point, not a physical server. | 3 |
| server_type | APP_SERVER | Application server (e.g., JBoss EAP). Monitored for HTTP responsiveness, service state, and application-level metrics by the DmOps module. | 4 |

**Active servers with module flags** [sort:1] -- Shows all active servers and which modules are enabled for each.

```sql
SELECT server_id, server_name, server_type, environment, ag_cluster_name,
       serverops_activity_enabled, serverops_backup_enabled,
       serverops_disk_enabled, serverops_maintenance_enabled,
       jobflow_enabled, batchops_enabled, fileops_enabled, bidata_enabled
FROM dbo.ServerRegistry
WHERE is_active = 1
ORDER BY server_name;
```

**Servers by AG cluster** [sort:2] -- Groups servers by Availability Group membership.

```sql
SELECT ag_cluster_name, server_name, server_type, server_role
FROM dbo.ServerRegistry
WHERE ag_cluster_name IS NOT NULL
  AND is_active = 1
ORDER BY ag_cluster_name, server_type;
```

  - **DatabaseRegistry**: [sort:1] Parent table. DatabaseRegistry.server_id references ServerRegistry.server_id to establish which server hosts each monitored database.
  - **ServerOps.DatabaseConfig**: [sort:2] Indirectly related through DatabaseRegistry. ServerOps component-specific settings for databases are linked via DatabaseRegistry.database_id, which links back to ServerRegistry.server_id.


### System_Metadata

Append-only version changelog for xFACts platform components. Each row records a single version bump for one component, capturing what changed and when. Current version for any component is the latest row by metadata_id. Replaces the previous per-object versioning model with component-level tracking.

**Data Flow:** Rows are inserted via the Admin page System Metadata modal or directly via SQL during development sessions. The table is append-only — rows are never updated or deleted. The Admin page reads the latest row per component_name to display current versions, and queries full history per component for the version history expansion.

**Append-only design:** [sort:1] Unlike the previous System_Metadata table which used ACTIVE/SUPERSEDED status tracking with an auto-supersede trigger, the new table is purely append-only. Current version is determined by querying the latest row (MAX metadata_id or TOP 1 ORDER BY metadata_id DESC) for a given component_name. This eliminates the need for status management, triggers, and the associated complexity.

**Sequential version counter:** [sort:2] Versions follow a three-place sequential pattern: 1.0.0, 1.0.1, ..., 1.0.9, 1.1.0, ..., 1.9.9, 2.0.0. The numbers carry no major/minor/patch semantics — each increment is just the next number. The description field carries all meaning about what changed. This eliminates the decision friction of choosing between major, minor, and patch bumps.

**One bump per session per component:** [sort:3] All changes to a component within a single working session are captured in one version entry. The description lists everything touched. This keeps the changelog meaningful without generating noise from individual file saves.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| metadata_id (IDENTITY) | int | No | IDENTITY | Auto-incrementing primary key. Also serves as a natural ordering key — higher metadata_id means more recent version. |
| module_name | varchar(50) | No | — | Functional module this version entry belongs to. Matches Component_Registry.module_name. |
| component_name | varchar(128) | No | — | Component being versioned. FK to Component_Registry.component_name. |
| version | varchar(20) | No | — | Three-place sequential version counter (e.g., 1.0.0, 1.0.1, 1.1.0). No semantic meaning — just the next number. Increments: 1.0.0 through 1.0.9, then 1.1.0 through 1.9.9, then 2.0.0. |
| description | varchar(4000) | Yes | — | What changed in this version — lists specific objects and files touched. |
| deployed_date | datetime | No | getdate() | When this version was deployed. Auto-populated via GETDATE() default. |
| deployed_by | varchar(100) | No | suser_sname() | Who deployed this version. Auto-populated via SUSER_SNAME() default. |

  - **PK_System_Metadata** (CLUSTERED): metadata_id -- PRIMARY KEY
  - **IX_System_Metadata_component** (NONCLUSTERED): component_name [includes: version, deployed_date, description]
  - **UQ_System_Metadata_component_version** (NONCLUSTERED): component_name, version

**Foreign Keys:**

  - **FK_System_Metadata_Component**: component_name -> dbo.Component_Registry.component_name
  - **FK_System_Metadata_Module**: module_name -> dbo.Module_Registry.module_name

**Current version per component** [sort:1] -- Returns the latest version for every active component. Uses ROW_NUMBER to pick the most recent entry by metadata_id.

```sql
SELECT sm.component_name, sm.version, sm.description, sm.deployed_date, sm.deployed_by
FROM dbo.System_Metadata sm
INNER JOIN (
    SELECT component_name, MAX(metadata_id) AS max_id
    FROM dbo.System_Metadata
    GROUP BY component_name
) latest ON sm.metadata_id = latest.max_id
ORDER BY sm.component_name;
```

**Full version history for a component** [sort:2] -- Returns all version entries for a specific component, newest first.

```sql
SELECT metadata_id, version, description, deployed_date, deployed_by
FROM dbo.System_Metadata
WHERE component_name = 'ServerOps.Index'
ORDER BY metadata_id DESC;
```

**Recent platform activity** [sort:3] -- Returns the most recent version bumps across all components. Useful for seeing what changed recently.

```sql
SELECT TOP 20
    sm.module_name, sm.component_name, sm.version, sm.description,
    sm.deployed_date, sm.deployed_by
FROM dbo.System_Metadata sm
ORDER BY sm.metadata_id DESC;
```

**Component version summary with object counts** [sort:4] -- Combines current version from System_Metadata with object count from Object_Registry. The dashboard view.

```sql
SELECT
    cr.module_name, cr.component_name, cr.description,
    COUNT(oreg.registry_id) AS object_count,
    sm.version AS current_version, sm.deployed_date
FROM dbo.Component_Registry cr
LEFT JOIN dbo.Object_Registry oreg
    ON oreg.component_name = cr.component_name AND oreg.is_active = 1
LEFT JOIN (
    SELECT component_name, version, deployed_date,
           ROW_NUMBER() OVER (PARTITION BY component_name ORDER BY metadata_id DESC) AS rn
    FROM dbo.System_Metadata
) sm ON sm.component_name = cr.component_name AND sm.rn = 1
WHERE cr.is_active = 1
GROUP BY cr.module_name, cr.component_name, cr.description, sm.version, sm.deployed_date
ORDER BY cr.module_name, cr.component_name;
```

  - **Component_Registry**: [sort:1] System_Metadata has a foreign key to Component_Registry on component_name. Version entries can only be recorded for registered components.
  - **Legacy.System_Metadata**: [sort:2] The previous dbo.System_Metadata table was renamed to Legacy.System_Metadata during the versioning rearchitecture. All historical per-object version data is preserved there. No migration or rollup was attempted — the new table starts at 3.0.0 per component to maintain continuity with legacy version numbering.


### sp_AddHoliday

Adds a single holiday to dbo.Holiday with optional weekend observation adjustment. Use for company-specific holidays or one-off closures not covered by sp_GenerateHolidays.

**Data Flow:** Accepts a holiday date, name, weekend observation flag, and preview flag. Applies Saturday-to-Friday / Sunday-to-Monday shifts when @ObserveWeekends = 1, appending "(Observed)" to the name. Checks for duplicate dates before inserting into dbo.Holiday. Preview mode (default) shows what would happen without making changes.

**Preview Mode Default:** [sort:1] Like other xFACts procedures, @PreviewOnly defaults to 1. This prevents accidental data changes when testing or exploring. The preview output shows original vs final date, day of week, and whether the holiday already exists.

**Idempotent by Date:** [sort:2] The procedure checks for existing holidays on the final date (after any weekend shift). If a holiday already exists on that date, insertion is skipped regardless of name. This makes repeated execution safe.

**Parameters:**

| Parameter | Type | Direction | Default | Description |
| --- | --- | --- | --- | --- |
| @HolidayDate | date | IN |  |  |
| @HolidayName | varchar(50) | IN |  |  |
| @ObserveWeekends | bit | IN |  |  |
| @PreviewOnly | bit | IN |  |  |

  - **Holiday**: [sort:1] Inserts rows into dbo.Holiday. Used for company-specific holidays or one-off closures not covered by sp_GenerateHolidays.
  - **sp_GenerateHolidays**: [sort:2] Complementary procedure. sp_GenerateHolidays handles standard annual US holidays in bulk; sp_AddHoliday handles individual additions.


### sp_GenerateHolidays

Generates standard company holidays for a given year and inserts them into dbo.Holiday. Automatically calculates floating holidays (Memorial Day, Thanksgiving) and applies weekend observation rules.

**Data Flow:** Accepts a year and preview flag. Calculates fixed-date holidays (New Year's, Independence Day, Veterans Day, Christmas) and floating holidays (Memorial Day, Labor Day, Thanksgiving, Day After Thanksgiving) using calendar arithmetic. Applies weekend observation rules to fixed-date holidays. Checks each date against existing dbo.Holiday rows to prevent duplicates, then inserts new entries.

**Company-Specific Holiday Selection:** [sort:1] Only holidays the company actually observes are generated. Some federal holidays (MLK Day, Presidents Day, Columbus Day) are excluded because the company does not observe them. The Day After Thanksgiving is included as a company holiday.

**Idempotent Execution:** [sort:2] Running the procedure multiple times for the same year is safe. Existing holidays are detected by date and skipped. This makes the procedure useful for both initial population and verification.

**Parameters:**

| Parameter | Type | Direction | Default | Description |
| --- | --- | --- | --- | --- |
| @Year | int | IN |  |  |
| @PreviewOnly | bit | IN |  |  |

  - **Holiday**: [sort:1] Bulk-populates dbo.Holiday with standard US holidays for a given year. The primary method for annual holiday calendar setup.
  - **sp_AddHoliday**: [sort:2] Complementary procedure. sp_AddHoliday handles individual additions for company-specific holidays; sp_GenerateHolidays handles the standard annual set.


### sp_LogProtectionViolation

Helper procedure that logs DDL protection violations via autonomous transaction. Called by TR_xFACts_ProtectCriticalObjects through a loopback linked server to ensure log entries persist despite the trigger's ROLLBACK.

**Data Flow:** Called by TR_xFACts_ProtectCriticalObjects through the xFACts_Loopback linked server. Receives violation details (timestamp, username, object name, event type, SQL text) and performs a simple INSERT into dbo.Protection_ViolationLog. Because the call comes through the loopback, it executes in a separate database session, ensuring the INSERT commits even though the calling trigger issues ROLLBACK.

**Autonomous Transaction Pattern:** [sort:1] SQL Server does not support autonomous transactions natively. The loopback linked server (xFACts_Loopback, pointing back to the same instance) creates a separate session. The procedure's INSERT commits when the procedure returns, independent of the caller's transaction state.

**No Error Handling by Design:** [sort:2] The procedure contains no TRY/CATCH. If the INSERT fails, the error propagates to the trigger, which catches it silently and proceeds with the DDL ROLLBACK. Protection is never compromised by logging failures.

**Parameters:**

| Parameter | Type | Direction | Default | Description |
| --- | --- | --- | --- | --- |
| @violation_dttm | datetime | IN |  |  |
| @username | nvarchar(100) | IN |  |  |
| @object_name | nvarchar(400) | IN |  |  |
| @event_type | nvarchar(200) | IN |  |  |
| @sql_text | nvarchar(MAX) | IN |  |  |

  - **TR_xFACts_ProtectCriticalObjects**: [sort:1] Called exclusively by the protection trigger via the xFACts_Loopback linked server. Not intended for direct execution.
  - **Protection_ViolationLog**: [sort:2] Target table. Each call inserts one row capturing the blocked DDL operation details.


### Sync-ClientHierarchy.ps1

Rebuilds dbo.ClientHierarchy from crs5_oltp creditor and creditor group tables using a recursive CTE to resolve the full group hierarchy in a single pass. Uses MERGE to insert new creditors, update changed metadata, and delete creditors removed from the source. The CTE walks all groups regardless of soft-delete status, capturing the hierarchy as it exists in DM. Active flags at creditor, parent group, and top parent levels enable discrepancy detection.

**Data Flow:** Reads crs5_oltp.dbo.crdtr and crs5_oltp.dbo.crdtr_grp on AVG-PROD-LSNR via a recursive CTE that resolves the entire creditor group hierarchy. Writes to dbo.ClientHierarchy via MERGE (insert new, update changed, delete removed). After the MERGE, stamps last_refreshed_dttm on unchanged rows so the timestamp reflects the sync cycle. Registered in ProcessRegistry for daily orchestrator execution.

**Full Hierarchy Walk:** [sort:1] The CTE does not filter on crdtr_grp_sft_dlt_flg. Soft-deleted groups are walked the same as active groups to capture the real DM hierarchy. Active flags at each level (creditor, parent group, top parent) let consumers identify discrepancies without going back to source tables.

**Unresolved Group Safety Net:** [sort:2] Creditors whose group chain cannot be resolved through the CTE (e.g., circular references, groups pointing to non-existent parents) fall back to self-reference, the same treatment as standalone creditors in Group 1. This prevents NULL failures in the MERGE while still including the creditor in the table.

**Timestamp Touch Pass:** [sort:3] The MERGE only updates rows where column values actually changed. Rows that matched but had no differences are not touched, leaving their last_refreshed_dttm stale. A follow-up UPDATE stamps these rows so last_refreshed_dttm always reflects that the sync ran, enabling staleness detection.

  - **dbo.ClientHierarchy**: [sort:1] Target table rebuilt by this script via MERGE. The script is the sole writer to this table.
  - **crs5_oltp.dbo.crdtr**: [sort:2] Source table for creditor records. All creditors are included regardless of status.
  - **crs5_oltp.dbo.crdtr_grp**: [sort:3] Source table for creditor group hierarchy. The recursive CTE walks this table from top-level groups down to leaf groups. All groups are included regardless of soft-delete flag.


### TR_xFACts_ProtectCriticalObjects

Database-scoped DDL trigger that prevents accidental DROP or ALTER operations on critical xFACts objects. Intercepts DDL commands across all schemas, checks against a hardcoded protected objects list, logs violation attempts via autonomous transaction through the xFACts_Loopback linked server, then rolls back the operation.

**Data Flow:** Fires on DDL events (DROP_TABLE, ALTER_TABLE, DROP_PROCEDURE, ALTER_PROCEDURE, DROP_VIEW, ALTER_VIEW, DROP_FUNCTION, ALTER_FUNCTION, DROP_TRIGGER, ALTER_TRIGGER). Extracts event details from EVENTDATA() XML. Checks the target object against a hardcoded protected list organized by schema. If protected, calls sp_LogProtectionViolation via the xFACts_Loopback linked server (autonomous transaction), then issues ROLLBACK and RAISERROR.

**Hardcoded Protection List:** [sort:1] Protected objects are maintained as string literals within the trigger definition. This was chosen because all xFACts objects should be protected by default, and anyone with permissions to create objects also has access to modify the trigger. A simple list is easy to audit. New modules must add their objects to the list as part of deployment.

**Self-Protecting:** [sort:2] The trigger protects itself. Attempts to DROP or ALTER TR_xFACts_ProtectCriticalObjects are intercepted and blocked. To modify the trigger, it must first be disabled (DISABLE TRIGGER ... ON DATABASE), modified, then re-enabled.

**ORIGINAL_LOGIN() for Identity:** [sort:3] The trigger captures the user identity using ORIGINAL_LOGIN() rather than SUSER_SNAME() or SYSTEM_USER. This returns the original login even when context switching via EXECUTE AS, ensuring the actual person who initiated the DDL is recorded.

  - **Protection_ViolationLog**: [sort:1] Target audit table. Every blocked DDL operation is logged here with full event details including the SQL text of the blocked command.
  - **sp_LogProtectionViolation**: [sort:2] Called via the xFACts_Loopback linked server to perform the INSERT in a separate transaction. This autonomous transaction pattern ensures the log entry survives the trigger's ROLLBACK.
  - **TR_System_Metadata_AutoSupersede**: [sort:3] Sibling protected trigger. Both triggers are in each other's protection scope.


### Orchestrator

### CycleLog

Engine heartbeat cycle log capturing one row per orchestrator cycle that found work to do. Provides aggregate metrics for cycle duration, task counts, and overall status for operational monitoring and troubleshooting.

**Data Flow:** Start-xFACtsOrchestrator.ps1 inserts a row at the beginning of each heartbeat cycle that identifies processes due for execution. Empty heartbeats (no processes due) do not create rows. The engine updates the row at cycle completion with end_dttm, duration_ms, aggregate task counts, and cycle_status. The Control Center Engine Room page queries CycleLog for engine health indicators and cycle history.

**Work-Only Logging:** [sort:1] Heartbeat cycles where no processes are due do not create CycleLog entries. This avoids filling the table with empty heartbeats and keeps every row meaningful for operational monitoring.

**Aggregate Metrics:** [sort:2] The tasks_due, tasks_executed, tasks_succeeded, tasks_failed, and tasks_skipped columns provide a complete cycle summary without requiring joins to TaskLog. This supports quick dashboard queries and health checks without touching the much larger task-level table.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| cycle_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for each engine cycle |
| start_dttm | datetime | No | getdate() | When the cycle began |
| end_dttm | datetime | Yes | — | When the cycle completed. NULL while cycle is running |
| duration_ms | int | Yes | — | Total cycle duration in milliseconds. Calculated at completion |
| tasks_due | int | Yes | — | Number of processes identified as due at the start of the cycle |
| tasks_executed | int | Yes | — | Number of processes the engine attempted to launch |
| tasks_succeeded | int | Yes | — | Number of tasks that completed with SUCCESS status |
| tasks_failed | int | Yes | — | Number of tasks that completed with FAILED or TIMEOUT status |
| tasks_skipped | int | Yes | — | Number of processes that were due but skipped (e.g., still running from a previous cycle) |
| cycle_status | varchar(20) | No | 'RUNNING' | Overall cycle outcome: RUNNING, SUCCESS, PARTIAL, or FAILED |
| error_message | varchar(MAX) | Yes | — | Engine-level error message if the cycle itself failed (not individual task errors) |

  - **PK_CycleLog** (CLUSTERED): cycle_id -- PRIMARY KEY
  - **IX_CycleLog_start_dttm** (NONCLUSTERED): start_dttm [includes: cycle_status, duration_ms, tasks_executed, tasks_failed]

**Check Constraints:**

  - **CK_CycleLog_cycle_status**: `([cycle_status]='FAILED' OR [cycle_status]='PARTIAL' OR [cycle_status]='SUCCESS' OR [cycle_status]='RUNNING')`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| cycle_status | RUNNING | Cycle is currently executing tasks. Set on initial insert. | 1 |
| cycle_status | SUCCESS | All tasks in the cycle completed successfully (tasks_failed = 0). | 2 |
| cycle_status | PARTIAL | Some tasks succeeded and some failed within the same cycle. | 3 |
| cycle_status | FAILED | Engine-level error prevented normal task execution. Individual task failures produce PARTIAL, not FAILED. | 4 |

**Recent Cycle History** [sort:1] -- Shows the most recent engine cycles with timing and task metrics.

```sql
SELECT TOP 20
    cycle_id,
    start_dttm,
    end_dttm,
    duration_ms,
    cycle_status,
    tasks_due,
    tasks_executed,
    tasks_succeeded,
    tasks_failed,
    tasks_skipped
FROM Orchestrator.CycleLog
ORDER BY start_dttm DESC;
```

**Failed or Partial Cycles** [sort:2] -- Isolates cycles with failures for troubleshooting.

```sql
SELECT 
    cycle_id,
    start_dttm,
    cycle_status,
    tasks_failed,
    tasks_succeeded,
    error_message
FROM Orchestrator.CycleLog
WHERE cycle_status IN ('FAILED', 'PARTIAL')
ORDER BY start_dttm DESC;
```

**Cycle Performance Trend** [sort:3] -- Average cycle duration by hour over the last 7 days for performance analysis.

```sql
SELECT 
    CAST(start_dttm AS DATE) AS cycle_date,
    DATEPART(HOUR, start_dttm) AS cycle_hour,
    COUNT(*) AS cycles,
    AVG(duration_ms) AS avg_duration_ms,
    MAX(duration_ms) AS max_duration_ms,
    SUM(tasks_executed) AS total_tasks
FROM Orchestrator.CycleLog
WHERE start_dttm >= DATEADD(DAY, -7, GETDATE())
  AND cycle_status != 'RUNNING'
GROUP BY CAST(start_dttm AS DATE), DATEPART(HOUR, start_dttm)
ORDER BY cycle_date DESC, cycle_hour DESC;
```

  - **TaskLog**: [sort:1] Each CycleLog row is the parent for one or more TaskLog entries via FK_TaskLog_CycleLog. Drilling down from a cycle to its tasks shows exactly which processes ran, their individual outcomes, and any error output.
  - **ProcessRegistry**: [sort:2] CycleLog does not directly reference ProcessRegistry. The cycle records aggregate metrics about what happened; the individual process linkage lives in TaskLog.


### ProcessRegistry

Configuration hub for all orchestrated processes. Defines scheduling, execution mode, dependency ordering, and tracks runtime status for each process managed by the Orchestrator v2 engine.

**Data Flow:** Rows are manually inserted when onboarding a new process to the orchestrator. Start-xFACtsOrchestrator.ps1 queries ProcessRegistry each heartbeat cycle to identify due processes based on run_mode, interval_seconds, scheduled_time, and running_count. After launching a process, the engine updates last_execution_dttm and increments running_count. On completion, either the engine (WAIT mode) or the Complete-OrchestratorTask callback (FIRE_AND_FORGET mode) updates last_execution_status, last_duration_ms, last_successful_date, and decrements running_count. Queue table INSERT triggers (e.g., TR_Teams_AlertQueue_QueueDepth, TR_Jira_TicketQueue_QueueDepth) increment running_count for queue-driven processes. The Control Center Engine Room page displays process status and scheduling information.

**Dual Execution Targets:** [sort:1] Each process populates either script_path (PowerShell launched as external process) or procedure_name (stored procedure via Invoke-Sqlcmd). CK_ProcessRegistry_execution_target ensures at least one is populated. This allows the engine to handle both execution styles without separate configuration tables.

**Configuration and Live Status Combined:** [sort:2] ProcessRegistry serves as both configuration table and runtime status tracker. The engine updates last_execution_dttm, last_execution_status, last_duration_ms, and running_count directly in the config row. This eliminates the need for a separate status table and ensures the engine always sees current state in a single query.

**Three Scheduling Models:** [sort:3] run_mode controls scheduling behavior: 0 = Disabled (never executes), 1 = Scheduled (interval-based when scheduled_time is NULL, time-based when scheduled_time is populated), 2 = Queue-driven (executes when running_count > 0, set by external triggers). Time-based processes use last_successful_date to prevent duplicate runs on the same day.

**Running Count Semantics:** [sort:4] running_count has different meanings by run_mode. For scheduled processes (run_mode=1), it tracks active instances to prevent overlap. For queue-driven processes (run_mode=2), it represents pending items to process — incremented by queue INSERT triggers and decremented by the processor script. Floor protection prevents the count from going below zero in case of mismatched decrements.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| process_id (IDENTITY) | int | No | IDENTITY | Unique identifier for each process configuration |
| module_name | varchar(50) | No | — | Functional module the process belongs to (e.g., ServerOps, JobFlow, Jira) |
| process_name | varchar(100) | No | — | Logical name for this process (e.g., Collect-ServerHealth, Monitor-JobFlow) |
| description | varchar(500) | Yes | — | Human-readable description of what the process does |
| script_path | varchar(500) | Yes | — | Full path to PowerShell script. Populated for script-based processes |
| procedure_name | varchar(200) | Yes | — | Schema-qualified stored procedure name. Populated for SP-based processes |
| execution_mode | varchar(20) | No | 'WAIT' | How the engine handles process execution. WAIT or FIRE_AND_FORGET |
| dependency_group | int | No | 1 | Numeric group controlling execution order. Lower groups execute first |
| interval_seconds | int | No | 300 | Seconds between executions for interval-based scheduling. Ignored for queue-driven processes |
| scheduled_time | time | Yes | — | Daily execution time for time-based scheduling. When populated, interval_seconds is ignored. Not used for queue-driven processes |
| timeout_seconds | int | Yes | — | Maximum expected duration in seconds. NULL disables timeout monitoring |
| run_mode | int | No | 1 | How the process is scheduled: 0 = Disabled, 1 = Scheduled (interval/time-based), 2 = Queue-driven (triggered by running_count > 0) |
| running_count | int | No | 0 | For scheduled processes: number of currently active instances. For queue-driven processes: number of pending items to process. Incremented before launch (scheduled) or by queue triggers (queue-driven), decremented/reset on completion |
| allow_concurrent | bit | No | 0 | When enabled, the engine launches new instances even when running_count > 0. Used for processes with batch claiming logic where multiple instances safely process different content |
| last_execution_dttm | datetime | Yes | — | When the process was last launched. Used by interval-based scheduling to determine if due |
| last_execution_status | varchar(20) | Yes | — | Result of the most recent execution: SUCCESS, FAILED, RUNNING, or TIMEOUT |
| last_duration_ms | int | Yes | — | Duration of the most recent execution in milliseconds |
| last_successful_date | date | Yes | — | Date of last successful execution. Used by time-based scheduling to prevent duplicate runs on the same day |
| cc_engine_slug | varchar(20) | Yes | — | Short slug used in engine card DOM IDs on the Control Center page that displays this process. The slug forms part of three IDs per card: card-engine-<slug>, engine-bar-<slug>, and engine-cd-<slug>. Required for active scheduled processes (run_mode = 1); NULL for queue processors (run_mode = 2) and inactive processes (run_mode = 0). The HTML populator validates each engine card's slug against this column. |
| cc_engine_label | varchar(50) | Yes | — | Text shown in the engine card's label span on the Control Center page. The HTML populator validates each card's rendered label against this column. Required for active scheduled processes (run_mode = 1); NULL for queue processors (run_mode = 2) and inactive processes (run_mode = 0). |
| cc_page_route | varchar(100) | Yes | — | Control Center page route on which this process appears as an engine card. The HTML populator validates engine card placement against this column, emitting ENGINE_CARD_PAGE_MISMATCH when a card appears on a page whose route does not match. Required for active scheduled processes (run_mode = 1); NULL for queue processors (run_mode = 2) and inactive processes (run_mode = 0). |
| cc_sort_order | int | Yes | — | Display order of this process's engine card within the page's engine row, ascending. Lower values render first (leftmost). The HTML populator validates declaration order against this column, emitting ENGINE_CARD_ORDER_MISMATCH when cards are emitted out of registry order. Required for active scheduled processes (run_mode = 1); NULL for queue processors (run_mode = 2) and inactive processes (run_mode = 0). |
| created_dttm | datetime | No | getdate() | When the record was created |
| created_by | varchar(100) | No | suser_sname() | Who created the record |
| modified_dttm | datetime | Yes | — | When the record was last modified |
| modified_by | varchar(100) | Yes | — | Who last modified the record |

  - **PK_ProcessRegistry** (CLUSTERED): process_id -- PRIMARY KEY
  - **IX_ProcessRegistry_runmode_group** (NONCLUSTERED): run_mode, dependency_group, interval_seconds [includes: process_name, script_path, procedure_name, execution_mode, scheduled_time, last_execution_dttm, running_count]
  - **UQ_ProcessRegistry_Module_Process** (NONCLUSTERED): module_name, process_name

**Check Constraints:**

  - **CK_ProcessRegistry_execution_mode**: `([execution_mode]='FIRE_AND_FORGET' OR [execution_mode]='WAIT')`
  - **CK_ProcessRegistry_execution_target**: `([script_path] IS NOT NULL OR [procedure_name] IS NOT NULL)`
  - **CK_ProcessRegistry_last_execution_status**: `([last_execution_status]='NOT_STARTED' OR [last_execution_status]='POLLING' OR [last_execution_status]='TIMEOUT' OR [last_execution_status]='RUNNING' OR [last_execution_status]='FAILED' OR [last_execution_status]='SUCCESS')`
  - **CK_ProcessRegistry_run_mode**: `([run_mode]=(2) OR [run_mode]=(1) OR [run_mode]=(0))`
  - **CK_ProcessRegistry_running_count**: `([running_count]>=(0))`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| execution_mode | WAIT | Engine launches the process and waits for completion, capturing stdout/stderr and exit code directly. | 4 |
| execution_mode | FIRE_AND_FORGET | Engine launches the process in the background and moves on. The process reports completion via the Complete-OrchestratorTask callback. | 5 |
| last_execution_status | SUCCESS | Most recent execution completed successfully. | 6 |
| last_execution_status | FAILED | Most recent execution completed with errors. | 7 |
| last_execution_status | RUNNING | Process is currently executing. | 8 |
| last_execution_status | TIMEOUT | Process exceeded its timeout_seconds threshold without completing. | 9 |
| last_execution_status | NOT_STARTED | Process has been registered but has not yet executed. | 10 |
| last_execution_status | POLLING | Process completed a cycle but reported no actionable work — used by collectors that found nothing new to process. | 11 |
| run_mode | 0 | Disabled — process is not executed by the engine. | 1 |
| run_mode | 1 | Scheduled — process uses interval-based or time-based scheduling. | 2 |
| run_mode | 2 | Queue-driven — process executes when running_count > 0, triggered by external queue INSERT triggers. | 3 |

**All Registered Processes with Schedule** [sort:1] -- Complete process inventory showing execution targets, scheduling configuration, and current runtime status.

```sql
SELECT 
    process_id,
    module_name,
    process_name,
    COALESCE(script_path, procedure_name) AS execution_target,
    execution_mode,
    dependency_group,
    CASE run_mode
        WHEN 0 THEN 'Disabled'
        WHEN 1 THEN CASE 
            WHEN scheduled_time IS NOT NULL 
                THEN 'Daily @ ' + CAST(scheduled_time AS VARCHAR(5))
            ELSE CAST(interval_seconds AS VARCHAR) + 's interval'
        END
        WHEN 2 THEN 'Queue-driven'
    END AS schedule_desc,
    running_count,
    last_execution_status,
    last_execution_dttm,
    last_duration_ms
FROM Orchestrator.ProcessRegistry
ORDER BY run_mode, dependency_group, process_name;
```

**Process Health Summary** [sort:2] -- Prioritizes failed and timed-out processes for quick triage.

```sql
SELECT 
    module_name,
    process_name,
    run_mode,
    running_count,
    last_execution_status,
    last_execution_dttm,
    DATEDIFF(MINUTE, last_execution_dttm, GETDATE()) AS minutes_ago,
    last_duration_ms
FROM Orchestrator.ProcessRegistry
ORDER BY 
    CASE WHEN last_execution_status = 'FAILED' THEN 0 
         WHEN last_execution_status = 'TIMEOUT' THEN 1
         ELSE 2 END,
    module_name, process_name;
```

**Queue-Driven Processes with Pending Work** [sort:3] -- Shows queue-driven processes that have items waiting to be processed.

```sql
SELECT 
    process_name,
    module_name,
    running_count AS pending_items,
    last_execution_dttm,
    last_execution_status
FROM Orchestrator.ProcessRegistry
WHERE run_mode = 2
  AND running_count > 0
ORDER BY process_name;
```

  - **CycleLog**: [sort:1] Each engine heartbeat cycle that finds due processes creates a CycleLog row. ProcessRegistry is queried to determine which processes are due, but there is no direct foreign key — CycleLog captures aggregate metrics per cycle rather than linking to specific processes.
  - **TaskLog**: [sort:2] Every process execution creates a TaskLog row with FK_TaskLog_ProcessRegistry pointing back to the process_id. TaskLog denormalizes module_name, process_name, dependency_group, and execution_target at execution time so historical records remain accurate even if ProcessRegistry changes.
  - **Queue Table Triggers**: [sort:3] Queue-driven processes (run_mode=2) are triggered by INSERT triggers on their respective queue tables. TR_Teams_AlertQueue_QueueDepth and TR_Jira_TicketQueue_QueueDepth increment running_count when new items are queued, causing the engine to launch the processor on the next heartbeat.


### TaskLog

Per-process execution log capturing individual task results within each engine cycle. Records timing, status, exit codes, and output/error content for every process execution, providing granular troubleshooting detail beneath the cycle-level [Orchestrator - CycleLog].

**Data Flow:** Start-xFACtsOrchestrator.ps1 inserts a row when launching each process within a cycle, capturing denormalized process identification and setting task_status to RUNNING (WAIT mode) or transitioning through RUNNING to LAUNCHED (FIRE_AND_FORGET mode). For WAIT mode, the engine updates the row upon process completion with end_dttm, duration_ms, task_status, exit_code, output_summary, and error_output. For FIRE_AND_FORGET mode, the Complete-OrchestratorTask callback in xFACts-OrchestratorFunctions.ps1 performs the update. The Control Center Engine Room page queries TaskLog for per-process execution history and troubleshooting detail.

**Denormalized Process Context:** [sort:1] TaskLog stores module_name, process_name, dependency_group, and execution_target at execution time even though it has FK_TaskLog_ProcessRegistry. If a process is later renamed, reconfigured, or removed, historical log entries remain accurate and self-contained.

**Two Update Patterns:** [sort:2] WAIT mode tasks are updated by the engine after process exit. FIRE_AND_FORGET tasks are updated by the process itself via the Complete-OrchestratorTask callback. Both patterns converge on the same final state — the task row always ends with a terminal status, timing data, and any output or error content.

**Output Truncation:** [sort:3] output_summary and error_output are VARCHAR(MAX) but the callback function truncates content to 4000 characters before insertion. This prevents extremely verbose script output from consuming excessive storage while preserving enough detail for troubleshooting.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| task_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for each task execution |
| cycle_id | bigint | No | — | FK to [Orchestrator - CycleLog]. Links this task to the engine cycle that launched it |
| process_id | int | No | — | FK to [Orchestrator - ProcessRegistry]. Links to the process configuration |
| module_name | varchar(50) | No | — | Module name captured at execution time |
| process_name | varchar(100) | No | — | Process name captured at execution time |
| dependency_group | int | No | — | Dependency group captured at execution time |
| execution_mode | varchar(20) | No | — | Execution mode used: WAIT or FIRE_AND_FORGET |
| execution_target | varchar(500) | No | — | Actual script path or procedure name that was executed |
| start_dttm | datetime | No | getdate() | When the task execution began |
| end_dttm | datetime | Yes | — | When the task completed. NULL while running or for LAUNCHED tasks awaiting callback |
| duration_ms | int | Yes | — | Task duration in milliseconds. Calculated at completion |
| task_status | varchar(20) | No | 'RUNNING' | Current task state: RUNNING, SUCCESS, FAILED, TIMEOUT, or LAUNCHED |
| exit_code | int | Yes | — | Process exit code (0 = success for PowerShell scripts). NULL for FIRE_AND_FORGET until callback |
| output_summary | varchar(MAX) | Yes | — | Captured stdout from the process, truncated to 4000 characters |
| error_output | varchar(MAX) | Yes | — | Captured stderr from the process |

  - **PK_TaskLog** (CLUSTERED): task_id -- PRIMARY KEY
  - **IX_TaskLog_cycle_id** (NONCLUSTERED): cycle_id [includes: process_name, task_status, duration_ms]
  - **IX_TaskLog_process_start** (NONCLUSTERED): process_id, start_dttm [includes: task_status, duration_ms, exit_code]

**Check Constraints:**

  - **CK_TaskLog_execution_mode**: `([execution_mode]='FIRE_AND_FORGET' OR [execution_mode]='WAIT')`
  - **CK_TaskLog_task_status**: `([task_status]='NOT_STARTED' OR [task_status]='POLLING' OR [task_status]='LAUNCHED' OR [task_status]='TIMEOUT' OR [task_status]='FAILED' OR [task_status]='SUCCESS' OR [task_status]='RUNNING')`

**Foreign Keys:**

  - **FK_TaskLog_CycleLog**: cycle_id -> Orchestrator.CycleLog.cycle_id
  - **FK_TaskLog_ProcessRegistry**: process_id -> Orchestrator.ProcessRegistry.process_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| task_status | RUNNING | Task has been launched and is actively executing. Initial status for WAIT mode tasks. | 1 |
| task_status | LAUNCHED | FIRE_AND_FORGET task has been started in the background. Awaiting callback from the process. | 2 |
| task_status | SUCCESS | Task completed successfully (exit code 0 for scripts). Terminal state. | 3 |
| task_status | FAILED | Task completed with a non-zero exit code or threw an error. Terminal state. | 4 |
| task_status | TIMEOUT | Task exceeded its timeout_seconds threshold without completing. Engine kills the process and sets this status. | 5 |

**Recent Task History** [sort:1] -- Shows the most recent task executions across all processes.

```sql
SELECT TOP 50
    t.task_id,
    t.cycle_id,
    t.module_name,
    t.process_name,
    t.execution_mode,
    t.task_status,
    t.start_dttm,
    t.duration_ms,
    t.exit_code
FROM Orchestrator.TaskLog t
ORDER BY t.start_dttm DESC;
```

**Failed Tasks with Error Detail** [sort:2] -- Isolates failed and timed-out tasks with error output for troubleshooting.

```sql
SELECT 
    t.task_id,
    t.process_name,
    t.module_name,
    t.task_status,
    t.start_dttm,
    t.exit_code,
    t.error_output,
    LEFT(t.output_summary, 500) AS output_preview
FROM Orchestrator.TaskLog t
WHERE t.task_status IN ('FAILED', 'TIMEOUT')
ORDER BY t.start_dttm DESC;
```

**Execution History for a Specific Process** [sort:3] -- Last 20 executions of a named process with timing and status.

```sql
SELECT TOP 20
    t.task_id,
    t.cycle_id,
    t.task_status,
    t.start_dttm,
    t.end_dttm,
    t.duration_ms,
    t.exit_code
FROM Orchestrator.TaskLog t
INNER JOIN Orchestrator.ProcessRegistry p ON t.process_id = p.process_id
WHERE p.process_name = 'Process-Name-Here'
ORDER BY t.start_dttm DESC;
```

**Drill Down to Tasks for a Specific Cycle** [sort:4] -- Shows all tasks within a given engine cycle ordered by dependency group and start time.

```sql
SELECT 
    t.task_id,
    t.process_name,
    t.dependency_group,
    t.execution_mode,
    t.task_status,
    t.duration_ms,
    t.exit_code,
    t.error_output
FROM Orchestrator.TaskLog t
WHERE t.cycle_id = @cycle_id
ORDER BY t.dependency_group, t.start_dttm;
```

  - **CycleLog**: [sort:1] Each task belongs to exactly one engine cycle via FK_TaskLog_CycleLog. The parent CycleLog row provides aggregate cycle-level metrics; TaskLog provides the per-process detail within that cycle.
  - **ProcessRegistry**: [sort:2] FK_TaskLog_ProcessRegistry links each task to its process configuration. However, TaskLog denormalizes key process fields at execution time, so the FK is primarily for joins rather than data integrity — historical accuracy is preserved in the denormalized columns.


### Start-xFACtsOrchestrator.ps1

NSSM-hosted orchestrator engine providing heartbeat-driven process scheduling with dependency group execution, timeout enforcement, and drain mode support.

**Data Flow:** Runs as the xFACtsOrchestrator NSSM Windows service on FA-SQLDBB. Reads heartbeat_interval_seconds and orchestrator_drain_mode from dbo.GlobalConfig. Each heartbeat cycle queries Orchestrator.ProcessRegistry to identify due processes. Inserts a CycleLog row per cycle and a TaskLog row per process launch. For WAIT mode processes, captures stdout/stderr and updates TaskLog and ProcessRegistry on completion. For FIRE_AND_FORGET processes, records LAUNCHED status and moves on. Sends CRITICAL Teams alerts directly to Teams.AlertQueue for WAIT mode timeout events.

**Dependency Group Execution:** [sort:1] Processes are organized into numbered dependency groups. Groups execute sequentially (all processes in group 10 complete before group 20 starts). Within a group, processes currently execute sequentially. Queue-driven processes are evaluated separately after all scheduled groups complete.

**Drain Mode:** [sort:2] When orchestrator_drain_mode is set to 1 in GlobalConfig, the engine skips new process launches but allows in-flight processes to complete naturally. A WARNING Teams alert fires once per engine startup if drain mode is active. Used for controlled maintenance shutdowns.

**WAIT Mode Timeout Enforcement:** [sort:3] WAIT mode processes have their timeout_seconds enforced by the engine. If a process exceeds its timeout, the engine kills the process, sets TIMEOUT status in TaskLog and ProcessRegistry, and queues a CRITICAL Teams alert directly via INSERT to Teams.AlertQueue with Orchestrator_Timeout trigger type.

  - **ProcessRegistry**: [sort:1] Reads process configuration and scheduling data each heartbeat. Updates runtime status fields (running_count, last_execution_dttm, last_execution_status, last_duration_ms) for WAIT mode processes.
  - **CycleLog**: [sort:2] Creates one row per heartbeat cycle that finds due processes. Updates with aggregate metrics and final status at cycle completion.
  - **TaskLog**: [sort:3] Creates one row per process launch within a cycle. Updates with final results for WAIT mode processes. FIRE_AND_FORGET task rows are updated by the process callback instead.
  - **xFACts-OrchestratorFunctions.ps1**: [sort:4] Companion function library dot-sourced by managed scripts. Provides the Complete-OrchestratorTask callback that FIRE_AND_FORGET processes use to report completion back to TaskLog and ProcessRegistry.


### xFACts-OrchestratorFunctions.ps1

PowerShell function library providing shared script infrastructure and task completion callback capabilities for scripts running under the Orchestrator v2 engine.

**Data Flow:** Dot-sourced by all xFACts PowerShell scripts at startup. Provides Initialize-XFActsScript for standardized SQL module loading, logging setup, and application identity tagging. The Complete-OrchestratorTask function updates Orchestrator.TaskLog (end_dttm, duration_ms, task_status, exit_code, output_summary, error_output) and Orchestrator.ProcessRegistry (running_count decrement, last_execution_status, last_duration_ms, last_successful_date). Also sends PROCESS_COMPLETED WebSocket events to the Control Center for real-time engine health indicator updates.

**Fail-Safe Callback:** [sort:1] Complete-OrchestratorTask catches all exceptions internally and writes a warning instead of throwing. A callback failure should not crash the calling script — the actual work was already done successfully.

**Dot-Sourcing Pattern:** [sort:2] Functions are loaded via dot-sourcing rather than a PowerShell module. This matches the pattern used by xFACts-IndexFunctions.ps1 and simplifies deployment — no module registration or path configuration required.

**Running Count Floor Protection:** [sort:3] The callback decrements running_count rather than setting it to zero, supporting concurrent execution scenarios. A CASE expression ensures running_count never goes below zero in case of mismatched decrements from race conditions or manual intervention.

**Real-Time Engine Events:** [sort:4] After updating database tables, Send-EngineEvent posts a PROCESS_COMPLETED event with scheduling metadata (interval_seconds, scheduled_time, run_mode) to the Control Center WebSocket endpoint. This enables live countdown timer updates on the Engine Room page without polling.

  - **TaskLog**: [sort:1] Complete-OrchestratorTask updates TaskLog with final execution results including timing, status, exit code, and captured output. This is the FIRE_AND_FORGET counterpart to the engine's direct WAIT mode updates.
  - **ProcessRegistry**: [sort:2] Complete-OrchestratorTask decrements running_count and updates last_execution_status, last_duration_ms, and last_successful_date on the process's ProcessRegistry row.
  - **Start-xFACtsOrchestrator.ps1**: [sort:3] The engine script passes TaskId and ProcessId parameters when launching FIRE_AND_FORGET processes. These IDs enable the callback function to update the correct TaskLog and ProcessRegistry rows.
  - **xFACts-IndexFunctions.ps1**: [sort:4] Uses the same dot-sourcing deployment pattern for shared function libraries. Both are loaded by their respective calling scripts via dot-source at the top of the file.


### dbo — RBAC

### RBAC_ActionGrant

Action-level permission overrides for the Control Center RBAC framework. Provides fine-grained ALLOW and DENY grants at the role or individual user level, supplementing the tier-based permissions defined in RBAC_ActionRegistry.

**Data Flow:** Rows are manually inserted when exceptions to the standard tier-based permissions are needed. The RBAC cache loads all active grants at startup. During action permission evaluation, the middleware first checks grant overrides before falling back to tier-based defaults. DENY grants are evaluated before ALLOW grants, and DENY always wins when both exist for the same user/action.

**DENY Takes Precedence:** [sort:1] When both ALLOW and DENY exist for the same user/action combination, DENY wins. This implements the principle of least privilege — it is safer to accidentally over-restrict than to accidentally over-permit.

**Role vs User Scope:** [sort:2] Most grants should be at the ROLE level. User-level grants (grant_scope = 'USER') are the escape hatch for situations where creating a new AD group and role mapping would be overkill. The check constraint enforces that exactly one of role_id or username is populated.

**Grant Evaluation Order:** [sort:3] The middleware evaluates: (1) user-level DENY, (2) role-level DENY, (3) user-level ALLOW, (4) role-level ALLOW, (5) tier-based default from RBAC_PermissionMapping + RBAC_ActionRegistry. The first match wins.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| grant_id (IDENTITY) | int | No | IDENTITY | Unique identifier for the grant |
| grant_type | varchar(5) | No | — | ALLOW or DENY. DENY always takes precedence over ALLOW |
| grant_scope | varchar(10) | No | — | ROLE (applies to a role) or USER (applies to a specific user) |
| action_id | int | No | — | Foreign key to RBAC_ActionRegistry. Identifies the action being granted or denied |
| role_id | int | Yes | — | Foreign key to RBAC_Role. Populated when grant_scope = 'ROLE' |
| username | varchar(100) | Yes | — | AD username without domain prefix. Populated when grant_scope = 'USER' |
| is_active | bit | No | 1 | Whether this grant is currently in effect |
| description | varchar(500) | Yes | — | Explanation of why this grant exists |
| created_dttm | datetime | No | getdate() | When the grant was created |
| created_by | varchar(100) | No | suser_sname() | Who created the grant |
| modified_dttm | datetime | Yes | — | When the grant was last modified |
| modified_by | varchar(100) | Yes | — | Who last modified the grant |

  - **PK_RBAC_ActionGrant** (CLUSTERED): grant_id -- PRIMARY KEY
  - **IX_RBAC_ActionGrant_action_id** (NONCLUSTERED): action_id

**Check Constraints:**

  - **CK_RBAC_ActionGrant_grant_scope**: `([grant_scope]='USER' OR [grant_scope]='ROLE')`
  - **CK_RBAC_ActionGrant_grant_type**: `([grant_type]='DENY' OR [grant_type]='ALLOW')`
  - **CK_RBAC_ActionGrant_scope_fields**: `([grant_scope]='ROLE' AND [role_id] IS NOT NULL AND [username] IS NULL OR [grant_scope]='USER' AND [username] IS NOT NULL AND [role_id] IS NULL)`

**Foreign Keys:**

  - **FK_RBAC_ActionGrant_ActionRegistry**: action_id -> dbo.RBAC_ActionRegistry.action_id
  - **FK_RBAC_ActionGrant_Role**: role_id -> dbo.RBAC_Role.role_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| grant_scope | ROLE | Grant applies to all users who hold the specified role. The standard approach for most overrides. | 1 |
| grant_scope | USER | Grant applies to a specific AD username. The exception path for one-off permissions that do not justify a new AD group. | 2 |
| grant_type | ALLOW | Grants access to an action the user would not normally have based on their tier. Example: ReadOnly users get ALLOW for kill-zombie because everyone loves killing zombie connections. | 1 |
| grant_type | DENY | Revokes access to an action the user would normally have. Always takes precedence over ALLOW. Example: PowerUser gets DENY for bulk-toggle-tasks because bulk operations on production flows are admin-only. | 2 |

**All active grants with action details** [sort:1] -- Shows every override with the action it applies to.

```sql
SELECT ag.grant_type, ag.grant_scope, 
       COALESCE(r.role_name, ag.username) AS grantee,
       ar.action_name, ar.page_route, ag.description
FROM dbo.RBAC_ActionGrant ag
JOIN dbo.RBAC_ActionRegistry ar ON ar.action_id = ag.action_id
LEFT JOIN dbo.RBAC_Role r ON r.role_id = ag.role_id
WHERE ag.is_active = 1
ORDER BY ag.grant_type DESC, ar.page_route, ar.action_name;
```

  - **RBAC_ActionRegistry**: [sort:1] Parent table. action_id references RBAC_ActionRegistry.action_id. Identifies which action the grant applies to.
  - **RBAC_Role**: [sort:2] Optional parent. role_id references RBAC_Role.role_id when grant_scope = 'ROLE'. NULL when grant_scope = 'USER'.


### RBAC_ActionRegistry

Registry of protectable actions in the Control Center. Defines which API endpoints require permission checks, what page they belong to, and what tier is required to execute them.

**Data Flow:** Rows are manually inserted when new protected API endpoints are created in the Control Center. The RBAC cache loads all active actions at startup. When an API route handler executes, it looks up the endpoint path and HTTP method in the cache to find the action's required_tier and page_route. The user's tier for that page (from RBAC_PermissionMapping) determines default access, with RBAC_ActionGrant providing overrides.

**Configuration-Driven Action Protection:** [sort:1] Before this table existed, action permission checks required hardcoded parameters at every API endpoint. Adding a new protected action meant code changes. With the registry, adding a protected endpoint is a single INSERT and the route handler only needs one line of code that reads everything else from the cached registry.

**Endpoint as Unique Key:** [sort:2] The combination of api_endpoint and http_method uniquely identifies an action. The route handler looks up permission requirements from $WebEvent.Path and $WebEvent.Method without knowing anything about the action's name or tier. action_name serves as the human-readable business key used in audit logs and ActionGrant overrides.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| action_id (IDENTITY) | int | No | IDENTITY | Unique identifier for the action |
| action_name | varchar(100) | No | — | Business key for the action (e.g., 'kill-zombie', 'toggle-task'). Used in audit logs and ActionGrant references |
| api_endpoint | varchar(200) | No | — | Full API path (e.g., '/api/server-health/kill-zombies') |
| http_method | varchar(10) | No | — | HTTP method: POST, PUT, or DELETE |
| page_route | varchar(200) | No | — | Parent page route for tier resolution (e.g., '/server-health') |
| required_tier | varchar(20) | No | — | Minimum tier required: admin, operate, or view |
| description | varchar(500) | No | — | What this action does |
| is_active | bit | No | 1 | Whether this action is currently enforced |
| created_dttm | datetime | No | getdate() | When the action was registered |
| created_by | varchar(100) | No | suser_sname() | Who registered the action |
| modified_dttm | datetime | Yes | — | When the action was last modified |
| modified_by | varchar(100) | Yes | — | Who last modified the action |

  - **PK_RBAC_ActionRegistry** (CLUSTERED): action_id -- PRIMARY KEY
  - **UQ_RBAC_ActionRegistry_action_name** (NONCLUSTERED): action_name
  - **UQ_RBAC_ActionRegistry_api_endpoint** (NONCLUSTERED): api_endpoint, http_method

**Check Constraints:**

  - **CK_RBAC_ActionRegistry_http_method**: `([http_method]='DELETE' OR [http_method]='PUT' OR [http_method]='POST')`
  - **CK_RBAC_ActionRegistry_required_tier**: `([required_tier]='view' OR [required_tier]='operate' OR [required_tier]='admin')`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| required_tier | admin | Only users with admin tier on the parent page can execute. Used for dangerous or configuration-level actions. | 1 |
| required_tier | operate | Users with operate or admin tier can execute. The default for most standard workflow actions. | 2 |
| required_tier | view | Any user with access to the page can execute. Used for actions that are safe for everyone, typically paired with ALLOW grants for broader access. | 3 |

**All registered actions by page** [sort:1] -- Shows every protected API endpoint grouped by parent page.

```sql
SELECT page_route, action_name, api_endpoint, http_method, required_tier, description
FROM dbo.RBAC_ActionRegistry
WHERE is_active = 1
ORDER BY page_route, action_name;
```

  - **RBAC_ActionGrant**: [sort:1] Child table. RBAC_ActionGrant.action_id references RBAC_ActionRegistry.action_id for ALLOW/DENY overrides on specific actions.
  - **RBAC_PermissionMapping**: [sort:2] Logical relationship. page_route values match entries in RBAC_PermissionMapping. The user's tier on the parent page determines their default access to the action.
  - **RBAC_AuditLog**: [sort:3] action_name from this table appears in RBAC_AuditLog entries when action-level permission checks are logged.


### RBAC_AuditLog

Logs permission evaluation events from the Control Center RBAC framework. Captures access denials, authentication events, and optionally all permission checks for compliance and troubleshooting.

**Data Flow:** Populated by the Control Center RBAC middleware during permission evaluation. Verbosity is controlled by the GlobalConfig setting ControlCenter.rbac_audit_verbosity: 'denials_only' logs only DENIED and WOULD_DENY events, 'all' logs every permission check. Rows are append-only. The ad_groups and resolved_roles columns capture the user's state at event time as denormalized comma-separated strings.

**Denormalized State Capture:** [sort:1] The user's AD groups and resolved roles are stored as comma-separated strings rather than normalized references. This captures the exact permission state at the time of the event, preserving accuracy even if roles, group memberships, or mappings change later.

**Three Enforcement Modes:** [sort:2] The RBAC framework supports disabled (no checks), audit (checks run but only log, never block), and enforce (checks run and block unauthorized access). During the audit-to-enforce transition, WOULD_DENY events provide visibility into what would be blocked before anyone gets locked out.

**Complementary to API_RequestLog:** [sort:3] API_RequestLog captures all HTTP requests for traffic and performance analysis. RBAC_AuditLog focuses specifically on authorization decisions — who was blocked, why, and what permissions they had. Together they provide complete request + authorization visibility.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| audit_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the audit event |
| event_type | varchar(30) | No | — | Type of event (see Event Types below) |
| username | varchar(100) | Yes | — | AD username of the user. NULL for unauthenticated events |
| ad_groups | varchar(2000) | Yes | — | Comma-separated list of the user's AD groups at time of event |
| resolved_roles | varchar(500) | Yes | — | Comma-separated list of roles resolved from AD groups |
| page_route | varchar(200) | Yes | — | Page route being accessed. NULL for login events |
| action_name | varchar(100) | Yes | — | Action being attempted. NULL for page-level access checks |
| required_tier | varchar(20) | Yes | — | Minimum tier required for the page/action |
| user_tier | varchar(20) | Yes | — | User's resolved tier for the page |
| result | varchar(20) | No | — | Outcome: ALLOWED, DENIED, or WOULD_DENY (audit mode) |
| detail | varchar(1000) | Yes | — | Additional context about the decision |
| client_ip | varchar(45) | Yes | — | Client IP address |
| event_dttm | datetime | No | getdate() | When the event occurred |

  - **PK_RBAC_AuditLog** (CLUSTERED): audit_id -- PRIMARY KEY
  - **IX_RBAC_AuditLog_result_event_dttm** (NONCLUSTERED): result, event_dttm
  - **IX_RBAC_AuditLog_username_event_dttm** (NONCLUSTERED): username, event_dttm

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| event_type | LOGIN_SUCCESS | User successfully authenticated via Active Directory. | 1 |
| event_type | LOGIN_FAILURE | Active Directory authentication failed. | 2 |
| event_type | ACCESS_DENIED | User lacks page-level permission. Logged in enforce mode. | 3 |
| event_type | ACCESS_AUDIT | User would lack page-level permission. Logged in audit mode without blocking. | 4 |
| event_type | ACTION_DENIED | User lacks action-level permission. Logged in enforce mode. | 5 |
| event_type | ACTION_AUDIT | User would lack action-level permission. Logged in audit mode without blocking. | 6 |
| event_type | PERMISSION_CHANGE | RBAC table configuration was modified through the admin interface. | 7 |
| result | ALLOWED | Permission check passed. Action or page access was granted. | 1 |
| result | DENIED | Permission check failed in enforce mode. Access was blocked. | 2 |
| result | WOULD_DENY | Permission check failed in audit mode. Access was allowed but the event was logged for impact assessment. | 3 |

**Recent denials** [sort:1] -- Shows blocked or would-be-blocked events in the last 7 days.

```sql
SELECT event_type, username, page_route, action_name,
       required_tier, user_tier, result, detail, event_dttm
FROM dbo.RBAC_AuditLog
WHERE result IN ('DENIED', 'WOULD_DENY')
  AND event_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY event_dttm DESC;
```

**Audit mode impact assessment** [sort:2] -- Shows how many users and pages would be affected by enabling enforcement.

```sql
SELECT username, page_route, action_name,
       COUNT(*) AS occurrence_count
FROM dbo.RBAC_AuditLog
WHERE result = 'WOULD_DENY'
  AND event_dttm >= DATEADD(DAY, -7, GETDATE())
GROUP BY username, page_route, action_name
ORDER BY occurrence_count DESC;
```

  - **RBAC_ActionRegistry**: [sort:1] Logical relationship. action_name values in audit entries correspond to RBAC_ActionRegistry.action_name. No physical foreign key since the audit log must persist even if actions are removed.
  - **API_RequestLog**: [sort:2] Complementary table. API_RequestLog captures HTTP request metrics; RBAC_AuditLog captures authorization decisions. Together they provide complete request-level visibility.
  - **GlobalConfig**: [sort:3] The ControlCenter.rbac_audit_verbosity setting controls logging volume. 'denials_only' keeps the table lean during normal operation; 'all' provides complete audit coverage when needed.


### RBAC_DepartmentRegistry

Registry of departmental pages in the Control Center. Maps department identifiers to their page routes and display names.

**Data Flow:** Rows are manually inserted when a new department is onboarded to the Control Center. The middleware uses this table to validate department-scoped access and to render navigation elements appropriate to each user. The department_key value is the join point to RBAC_RoleMapping.department_scope.

**Department Key as URL Slug:** [sort:1] The department_key is a URL-friendly slug (e.g., 'business-services') used both as the RBAC_RoleMapping.department_scope join key and as part of the page route path. This keeps URLs clean and routing simple without needing a separate URL-to-department lookup.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| department_id (IDENTITY) | int | No | IDENTITY | Unique identifier for the department |
| department_key | varchar(50) | No | — | URL-friendly identifier (e.g., 'business-services'). Matches RBAC_RoleMapping.department_scope |
| department_name | varchar(100) | No | — | Display name (e.g., 'Business Services') |
| page_route | varchar(200) | No | — | Control Center page route (e.g., '/departmental/business-services') |
| is_active | bit | No | 1 | Whether this department page is currently active |
| created_dttm | datetime | No | getdate() | When the department page was registered |
| created_by | varchar(100) | No | suser_sname() | Who registered the department page |
| modified_dttm | datetime | Yes | — | When the department page was last modified |
| modified_by | varchar(100) | Yes | — | Who last modified the department page |

  - **PK_RBAC_DepartmentRegistry** (CLUSTERED): department_id -- PRIMARY KEY
  - **UQ_RBAC_DepartmentRegistry_key** (NONCLUSTERED): department_key
  - **UQ_RBAC_DepartmentRegistry_route** (NONCLUSTERED): page_route

**Active departments with role mapping count** [sort:1] -- Shows registered departments and how many role mappings exist for each.

```sql
SELECT dr.department_key, dr.department_name, dr.page_route,
       COUNT(rm.mapping_id) AS role_mapping_count
FROM dbo.RBAC_DepartmentRegistry dr
LEFT JOIN dbo.RBAC_RoleMapping rm ON rm.department_scope = dr.department_key
                                  AND rm.is_active = 1
WHERE dr.is_active = 1
GROUP BY dr.department_key, dr.department_name, dr.page_route
ORDER BY dr.department_name;
```

  - **RBAC_RoleMapping**: [sort:1] Logical relationship. RBAC_RoleMapping.department_scope matches department_key to scope roles to specific departments. No physical foreign key — validated at the application layer.


### RBAC_NavRegistry

Master inventory of Control Center pages with navigation metadata. Each row represents a CC page with its display label, page title, description, section grouping, sort order, optional documentation page link, and visibility flags controlling whether it appears in the page-level nav bar and the Home page tile grid. Joined with RBAC_PermissionMapping to filter visible pages per user role.

**Data Flow:** Rows are manually inserted when new CC pages are added to the platform. The Get-NavBarHtml helper function (xFACts-Helpers.psm1) reads this table at startup, joined with RBAC_NavSection for section grouping and with RBAC_PermissionMapping for per-user filtering, to render navigation HTML across all CC route files. Home.ps1 reads the same data filtered by show_on_home=1 to render the tile grid. Cached alongside other RBAC data with 5-minute refresh.

**Three-Field Text Model:** [sort:1] Three separate text columns serve different rendering contexts: nav_label (compact, fits in horizontal nav bar), display_title (prominent page header and tile heading), and description (longer subtitle and tile description). Most pages have nav_label = display_title, but separating them allows the nav bar to use abbreviations while the page header remains formal.

**Decoupled Visibility Flags:** [sort:2] show_in_nav and show_on_home are independent flags rather than a combined visibility mode. This allows pages like /client-portal to render as a Home tile but not in the horizontal nav (accessed only from Home), or /admin to be cataloged in the registry without rendering anywhere standard.

**Home Excluded by Convention:** [sort:3] The root route / is intentionally not stored in RBAC_NavRegistry. Home is treated as the universal first link in the nav bar by the Get-NavBarHtml helper function rather than as a registered page. This avoids special-case sort_order handling and keeps the registry as a clean catalog of destination pages.

**doc_page_id Convention:** [sort:4] The doc_page_id column stores the slug, not the full URL. Helper code constructs /docs/pages/{doc_page_id}.html. This matches the doc_page_id convention used in Component_Registry and centralizes the URL pattern in one place — if the docs URL pattern changes, only the helper updates, not the data.

**Permission Filtering at Render Time:** [sort:5] RBAC_NavRegistry does not store permissions. The helper function joins this table with RBAC_PermissionMapping at render time to filter pages to those the current user can access. This separates "what pages exist" (NavRegistry) from "who can access them" (PermissionMapping), and avoids data duplication between the two RBAC concerns.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| nav_id (IDENTITY) | int | No | IDENTITY | Auto-incrementing primary key. |
| page_route | varchar(200) | No | — | CC route path (e.g., /server-health, /departmental/business-services). Joins to RBAC_PermissionMapping.page_route for permission filtering. Unique within the table. |
| nav_label | varchar(100) | No | — | Short label displayed in the horizontal nav bar. Optimized for compact horizontal display (e.g., "Apps/Int" rather than "Applications & Integration"). |
| display_title | varchar(150) | No | — | Display title used for the page H1 header and the Home page tile heading. Often matches nav_label but may differ when the nav-bar abbreviation is too short for prominent display. |
| description | varchar(500) | Yes | — | Longer descriptive text used for the page subtitle and Home page tile description. NULL when no description is needed. |
| section_key | varchar(50) | No | — | Foreign key to RBAC_NavSection.section_key. Determines which top-level grouping this page belongs to. |
| sort_order | int | No | — | Numeric ordering within the page section. Increments of 10 for easy insertion of new pages without renumbering. Lower values render first. |
| doc_page_id | varchar(50) | Yes | — | Documentation page slug used to build the docs link. Helper function constructs URL as /docs/pages/{doc_page_id}.html. NULL means no documentation link is rendered for this page. |
| show_in_nav | bit | No | 1 | Controls visibility in the horizontal page-level nav bar. 1 = appears in nav, 0 = hidden from nav (e.g., admin gear targets, tile-only access pages). |
| show_on_home | bit | No | 1 | Controls visibility as a tile on the Home page. 1 = appears as tile, 0 = hidden from Home (e.g., admin pages, deep-link-only utility pages). |
| is_active | bit | No | 1 | Soft delete flag. 0 = retired or future page, fully hidden from all rendering but preserved for historical reference. |
| created_dttm | datetime | No | getdate() | When this page was registered. Auto-populated via default. |
| created_by | varchar(100) | No | suser_sname() | Who registered this page. Auto-populated via SUSER_SNAME() default. |
| modified_dttm | datetime | Yes | — | When this page was last modified. NULL until first update. |
| modified_by | varchar(100) | Yes | — | Who last modified this page. NULL until first update. |

  - **PK_RBAC_NavRegistry** (CLUSTERED): nav_id -- PRIMARY KEY
  - **IX_RBAC_NavRegistry_section_sort** (NONCLUSTERED): section_key, sort_order [includes: page_route, nav_label, display_title, doc_page_id, show_in_nav, show_on_home]
  - **UQ_RBAC_NavRegistry_page_route** (NONCLUSTERED): page_route

**Foreign Keys:**

  - **FK_RBAC_NavRegistry_NavSection**: section_key -> dbo.RBAC_NavSection.section_key

**All active pages by section** [sort:1] -- Lists all active nav registry rows grouped by section in render order.

```sql
SELECT 
    ns.section_label,
    nv.sort_order,
    nv.page_route,
    nv.nav_label,
    nv.display_title,
    nv.show_in_nav,
    nv.show_on_home
FROM dbo.RBAC_NavRegistry nv
JOIN dbo.RBAC_NavSection ns ON ns.section_key = nv.section_key
WHERE nv.is_active = 1 AND ns.is_active = 1
ORDER BY ns.section_sort_order, nv.sort_order;
```

**NavRegistry vs PermissionMapping coverage check** [sort:2] -- Identifies pages registered in NavRegistry that have no corresponding RBAC_PermissionMapping row, and vice versa. Both should be in sync — orphans on either side indicate a registration gap.

```sql
WITH nav_pages AS (
    SELECT DISTINCT page_route FROM dbo.RBAC_NavRegistry WHERE is_active = 1
),
perm_pages AS (
    SELECT DISTINCT page_route 
    FROM dbo.RBAC_PermissionMapping 
    WHERE is_active = 1 AND page_route NOT IN ('*', '/')
)
SELECT 
    COALESCE(n.page_route, p.page_route) AS page_route,
    CASE 
        WHEN n.page_route IS NULL THEN 'In PermissionMapping only - missing NavRegistry row'
        WHEN p.page_route IS NULL THEN 'In NavRegistry only - missing PermissionMapping row'
    END AS gap_description
FROM nav_pages n
FULL OUTER JOIN perm_pages p ON p.page_route = n.page_route
WHERE n.page_route IS NULL OR p.page_route IS NULL
ORDER BY page_route;
```

**Pages visible to a specific user (preview)** [sort:3] -- Shows what pages a specific user would see in nav and home, accounting for both NavRegistry visibility flags and their RBAC permissions.

```sql
DECLARE @username VARCHAR(100) = 'dcota';

WITH user_routes AS (
    SELECT DISTINCT pm.page_route
    FROM dbo.RBAC_PermissionMapping pm
    JOIN dbo.RBAC_RoleMapping rm ON rm.role_id = pm.role_id
    -- Note: this is a simplified check; the real middleware also resolves
    -- AD groups, this query is for preview/diagnostic purposes only.
    WHERE pm.is_active = 1 AND rm.is_active = 1
)
SELECT 
    ns.section_label,
    nv.nav_label,
    nv.show_in_nav,
    nv.show_on_home,
    CASE WHEN ur.page_route IS NOT NULL THEN 'yes' ELSE 'no' END AS user_has_permission
FROM dbo.RBAC_NavRegistry nv
JOIN dbo.RBAC_NavSection ns ON ns.section_key = nv.section_key
LEFT JOIN user_routes ur ON ur.page_route = nv.page_route
WHERE nv.is_active = 1
ORDER BY ns.section_sort_order, nv.sort_order;
```

  - **RBAC_NavSection**: [sort:1] Parent table. RBAC_NavRegistry.section_key references RBAC_NavSection.section_key via FK. Determines section grouping and accent styling.
  - **RBAC_PermissionMapping**: [sort:2] Logical relationship (no physical FK). NavRegistry.page_route is joined to RBAC_PermissionMapping.page_route at render time to filter the visible page set per user role. Pages in NavRegistry without corresponding PermissionMapping rows would be rendered for nobody.


### RBAC_NavSection

Section groupings for the dynamic Control Center navigation. Each section represents a top-level grouping of CC pages (Platform, Departmental Pages, Tools, Administration) with display order and visual accent styling. Referenced by RBAC_NavRegistry to organize page rows into sections.

**Data Flow:** Rows are manually inserted when a new top-level navigation grouping is needed. The Get-NavBarHtml helper function (xFACts-Helpers.psm1) reads this table at startup, joined with RBAC_NavRegistry, to render section-grouped navigation links across all CC pages and Home page tile groupings. The accent_class column drives section-level visual styling via CSS classes defined in engine-events.css. Cached alongside other RBAC data with 5-minute refresh.

**Section vs. Page Separation:** [sort:1] Section-level metadata (label, color, ordering) is stored separately from page-level metadata (RBAC_NavRegistry) to avoid duplication. All pages within a section share the same accent styling and label, so storing it once at the section level keeps the data normalized. Adding a new section is a single INSERT here; pages reference it via the section_key foreign key.

**Color via CSS Class Not Hex:** [sort:2] The accent_class column stores a CSS class name rather than a literal color value. This decouples presentation (colors, hover effects, dark mode variants) from data, allowing visual changes without database updates. Class definitions live in engine-events.css.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| section_id (IDENTITY) | int | No | IDENTITY | Auto-incrementing primary key. |
| section_key | varchar(50) | No | — | URL-safe identifier used as foreign key target by RBAC_NavRegistry.section_key. Examples: platform, departmental, tools, admin. |
| section_label | varchar(100) | No | — | Display text rendered as section header on the Home page tile grid. Also used as the conceptual label for nav-bar separator areas. |
| section_sort_order | int | No | — | Numeric ordering for section display. Increments of 10 for easy insertion of new sections without renumbering. Lower values render first. |
| accent_class | varchar(50) | Yes | — | CSS class name applied to section elements for visual styling (color theme). Class definitions live in engine-events.css. NULL means no section-level accent styling. |
| is_active | bit | No | 1 | Soft delete flag. 0 = retired section, hidden from rendering but preserved for historical reference. |
| created_dttm | datetime | No | getdate() | When this section was registered. Auto-populated via default. |
| created_by | varchar(100) | No | suser_sname() | Who registered this section. Auto-populated via SUSER_SNAME() default. |

  - **PK_RBAC_NavSection** (CLUSTERED): section_id -- PRIMARY KEY
  - **UQ_RBAC_NavSection_section_key** (NONCLUSTERED): section_key

  - **RBAC_NavRegistry**: [sort:1] Child table. RBAC_NavRegistry.section_key references RBAC_NavSection.section_key via FK. Each nav registry row belongs to exactly one section.


### RBAC_PermissionMapping

Defines what each role can do on each Control Center page. Maps roles to pages with a permission tier that controls whether the user can view, operate, or administer the page.

**Data Flow:** Rows are manually inserted when configuring page access for roles. The RBAC middleware cache loads all active permissions at startup. When a user requests a page, the middleware resolves their roles (from RBAC_RoleMapping) and checks this table to determine their highest permission tier for that page. The tier controls both page visibility in navigation and action availability on the page.

**Wildcard Route for Admin:** [sort:1] The Admin role uses page_route = '*' to grant access to all pages without needing a row per page. This simplifies administration and ensures Admin access is never accidentally omitted from a new page.

**Tier Hierarchy Resolution:** [sort:2] admin > operate > view. When a user has multiple roles (e.g., ReadOnly platform-wide + DeptStaff for a department), the middleware takes the highest applicable tier for each page. A user is never downgraded by having additional roles.

**API Route Inheritance:** [sort:3] Page routes are stored as exact paths (e.g., '/server-health'). API routes under a page inherit the parent page's permission — '/api/server-health/*' checks against '/server-health'. This avoids needing separate permission rows for every API endpoint.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| permission_id (IDENTITY) | int | No | IDENTITY | Unique identifier for the permission |
| role_id | int | No | — | Foreign key to RBAC_Role |
| page_route | varchar(200) | No | — | Page route this permission applies to. Use '*' for all pages |
| permission_tier | varchar(20) | No | — | Permission level: admin, operate, or view |
| is_active | bit | No | 1 | Whether this permission is currently in effect |
| created_dttm | datetime | No | getdate() | When the permission was created |
| created_by | varchar(100) | No | suser_sname() | Who created the permission |
| modified_dttm | datetime | Yes | — | When the permission was last modified |
| modified_by | varchar(100) | Yes | — | Who last modified the permission |

  - **PK_RBAC_PermissionMapping** (CLUSTERED): permission_id -- PRIMARY KEY
  - **UQ_RBAC_PermissionMapping_role_page** (NONCLUSTERED): role_id, page_route

**Check Constraints:**

  - **CK_RBAC_PermissionMapping_tier**: `([permission_tier]='view' OR [permission_tier]='operate' OR [permission_tier]='admin')`

**Foreign Keys:**

  - **FK_RBAC_PermissionMapping_Role**: role_id -> dbo.RBAC_Role.role_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| permission_tier | admin | Full access to the page including all administrative and destructive actions. | 1 |
| permission_tier | operate | Standard workflow access. Can perform normal operational actions but not administrative functions. | 2 |
| permission_tier | view | Read-only access. Page is visible in navigation but no action buttons are rendered. | 3 |

**Permission matrix (role x page)** [sort:1] -- Shows the complete authorization matrix.

```sql
SELECT r.role_name, pm.page_route, pm.permission_tier
FROM dbo.RBAC_PermissionMapping pm
JOIN dbo.RBAC_Role r ON r.role_id = pm.role_id
WHERE pm.is_active = 1
ORDER BY r.display_order, pm.page_route;
```

  - **RBAC_Role**: [sort:1] Parent table. role_id references RBAC_Role.role_id. Each permission row assigns one role a tier on one page.
  - **RBAC_ActionRegistry**: [sort:2] Logical relationship. RBAC_ActionRegistry.page_route values match entries in this table. The user's tier on a page determines their default access to actions registered under that page.


### RBAC_Role

Role definitions for the xFACts Control Center RBAC framework. Each role represents a permission tier that determines what users can see and do.

**Data Flow:** Rows are manually inserted when new roles are defined. The RBAC middleware cache loads all active roles at Control Center startup. RBAC_RoleMapping references role_id to connect AD groups to roles. RBAC_PermissionMapping references role_id to define page-level access. RBAC_ActionGrant references role_id for role-scoped ALLOW/DENY overrides.

**Three-Tier Permission Model:** [sort:1] Three tiers cover the vast majority of use cases: admin (full access including destructive actions), operate (standard workflow actions), view (read-only). Finer-grained control is handled through RBAC_ActionGrant rather than creating additional tiers.

**Platform vs Departmental Roles:** [sort:2] The same table holds both platform-wide roles (Admin, PowerUser, StandardUser, ReadOnly) and departmental roles (DeptManager, DeptStaff). The distinction is made in RBAC_RoleMapping through the department_scope column, not in the role definition itself. This enables role reuse across departments.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| role_id (IDENTITY) | int | No | IDENTITY | Unique identifier for the role |
| role_name | varchar(50) | No | — | Unique role name (e.g., Admin, PowerUser, DeptStaff) |
| role_tier | varchar(20) | No | — | Permission tier: admin, operate, or view |
| display_order | int | No | 0 | Sort order for UI rendering. Lower numbers appear first |
| description | varchar(500) | No | — | What this role provides access to |
| is_active | bit | No | 1 | Whether this role is currently in use |
| created_dttm | datetime | No | getdate() | When the role was created |
| created_by | varchar(100) | No | suser_sname() | Who created the role |

  - **PK_RBAC_Role** (CLUSTERED): role_id -- PRIMARY KEY
  - **UQ_RBAC_Role_role_name** (NONCLUSTERED): role_name

**Check Constraints:**

  - **CK_RBAC_Role_role_tier**: `([role_tier]='view' OR [role_tier]='operate' OR [role_tier]='admin')`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| role_tier | admin | Full access including destructive and configuration actions. Reserved for the Applications Team. | 1 |
| role_tier | operate | Standard workflow actions: assign requests, close tasks, kill zombie connections. The default for most active users. | 2 |
| role_tier | view | Read-only access. Can see data and dashboards but cannot perform any actions. Like window shopping for database metrics. | 3 |

**All active roles with tier** [sort:1] -- Shows the role hierarchy by display order.

```sql
SELECT role_id, role_name, role_tier, display_order, description
FROM dbo.RBAC_Role
WHERE is_active = 1
ORDER BY display_order;
```

  - **RBAC_RoleMapping**: [sort:1] Child table. RBAC_RoleMapping.role_id references RBAC_Role.role_id. Maps AD groups to roles with optional department scoping.
  - **RBAC_PermissionMapping**: [sort:2] Child table. RBAC_PermissionMapping.role_id references RBAC_Role.role_id. Defines what tier each role has on each page.
  - **RBAC_ActionGrant**: [sort:3] Child table. RBAC_ActionGrant.role_id references RBAC_Role.role_id for role-scoped ALLOW/DENY overrides on specific actions.


### RBAC_RoleMapping

Maps Active Directory security groups to RBAC roles with optional department scoping. This is where AD group membership translates into Control Center permissions.

**Data Flow:** Rows are manually inserted when establishing the connection between AD groups and roles. When a user logs in, the Control Center middleware captures their AD group memberships, looks them up in this table, and resolves which roles they hold. The resolved roles then drive page access via RBAC_PermissionMapping and action permissions via RBAC_ActionGrant.

**Separation of Responsibilities:** [sort:1] IT Ops manages who is in which AD group (hiring, transfers, departures). The Applications Team manages what those groups mean within the Control Center via these mapping rows. Neither team needs to coordinate with the other for routine access changes.

**Department Scope Mechanism:** [sort:2] NULL department_scope means the role applies platform-wide (Admin, PowerUser, etc.). A non-NULL value (e.g., 'business-services') scopes the role to that department's pages only. This enables the same DeptStaff role definition to be reused across departments while the AD group provides department-specific context.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| mapping_id (IDENTITY) | int | No | IDENTITY | Unique identifier for the mapping |
| ad_group_name | varchar(100) | No | — | Active Directory group name (e.g., XCC-Admin, XCC-BusSvcsStaff) |
| role_id | int | No | — | Foreign key to RBAC_Role |
| department_scope | varchar(50) | Yes | — | Department key this mapping applies to. NULL = platform-wide. Matches RBAC_DepartmentPage.department_key |
| is_active | bit | No | 1 | Whether this mapping is currently in effect |
| created_dttm | datetime | No | getdate() | When the mapping was created |
| created_by | varchar(100) | No | suser_sname() | Who created the mapping |
| modified_dttm | datetime | Yes | — | When the mapping was last modified |
| modified_by | varchar(100) | Yes | — | Who last modified the mapping |

  - **PK_RBAC_RoleMapping** (CLUSTERED): mapping_id -- PRIMARY KEY
  - **UQ_RBAC_RoleMapping_group_role** (NONCLUSTERED): ad_group_name, role_id, department_scope

**Foreign Keys:**

  - **FK_RBAC_RoleMapping_Role**: role_id -> dbo.RBAC_Role.role_id

**All active mappings with role details** [sort:1] -- Shows which AD groups map to which roles and at what scope.

```sql
SELECT rm.ad_group_name, r.role_name, r.role_tier, rm.department_scope
FROM dbo.RBAC_RoleMapping rm
JOIN dbo.RBAC_Role r ON r.role_id = rm.role_id
WHERE rm.is_active = 1
ORDER BY rm.department_scope, r.display_order;
```

  - **RBAC_Role**: [sort:1] Parent table. role_id references RBAC_Role.role_id. Each mapping assigns one AD group to one role.
  - **RBAC_DepartmentRegistry**: [sort:2] Logical relationship. The department_scope value matches RBAC_DepartmentRegistry.department_key to scope the role to a specific department's pages. No physical foreign key — validated at the application layer.



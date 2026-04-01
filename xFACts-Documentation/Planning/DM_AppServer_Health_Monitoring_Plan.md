# DM App Server Health Monitoring — Investigation Plan

## The Problem

The Debt Manager application runs on JBoss hosted on dedicated app servers (dm-prod-app2, dm-prod-app3). Periodically — roughly 4-5 times over the last 2 years — the JBoss process freezes. The Windows service shows as running but the application becomes completely unresponsive. No new requests are processed, which causes blocking storms and open transaction pileup on the database side (one incident showed 136 open transactions with massive blocking and waits on Server Health).

The current remediation is manual: someone notices the issue, RDPs to the app server, restarts the JBoss service (3-5 minute restart), and if needed, the SharePoint navigation link is updated to redirect users to the alternate app server while recovery completes.

## What We Know

- **Affected servers:** dm-prod-app2 (primary), dm-prod-app3 (alternate)
- **Application URL:** `http://dm-prod-app2.fac.local/CRSServicesWeb/#`
- **Behavior when frozen:** JBoss process is running, but the app stops responding to all requests. No errors, no crashes — just a complete freeze.
- **Database impact:** xFACts Server Health has already detected the downstream symptoms (blocking, open transactions, wait stats) during past incidents. Extended Events and DMV collection pick up the impact but don't currently trigger automated response.
- **SharePoint link:** Top navigation link on SharePoint Online (365) points users to the primary app server. Manual update required to redirect traffic during incidents.
- **Frequency:** Infrequent but impactful. ~4-5 occurrences in 2 years.

## Detection Approaches to Investigate

### 1. HTTP Health Check (Primary — Fastest Detection)

Hit the app URL on a schedule (every 60 seconds) and check for a response. If JBoss is frozen, the request will timeout. This detects the problem directly at the source, before blocking builds up on the database side.

**What to figure out:**
- Does the app URL return a standard HTTP 200 when healthy?
- What's a reasonable timeout threshold? (10-15 seconds?)
- Can we use `Invoke-WebRequest` from FA-SQLDBB, or do we need to run from a server with line of sight to the app servers?
- Should we check both app servers on every cycle for full visibility?

### 2. Database-Side Correlation (Secondary — Already Partially in Place)

xFACts is already collecting blocked process events, connection health, and wait stats. A sudden spike of blocked sessions originating from a specific app server, combined with connection counts going flat, is a strong indicator.

**What to figure out:**
- Can we query the existing Activity tables to identify blocking patterns tied to a specific app server hostname?
- What thresholds would distinguish a JBoss freeze from normal heavy processing?
- Could sp_Activity_CorrelateIncidents be extended to flag this pattern?

### 3. Windows Process Monitoring (Supplementary)

CIM/WMI query against the app server checking JBoss process metrics. A process that's running but consuming zero CPU while holding high memory could indicate a freeze.

**What to figure out:**
- Does FAC\sqlmon have WinRM/CIM access to the app servers?
- What's the JBoss process name on Windows?
- Are there JBoss-specific health endpoints (JMX, management console) we could query?

## Remediation Options

### Automatic JBoss Restart

If FAC\sqlmon has service control access on the app servers, xFACts could restart JBoss automatically on confirmed freeze detection. This would need safeguards: confirmation via multiple consecutive failed health checks, cooldown period to prevent restart loops, and alerting before and after the action.

### SharePoint Navigation Link Toggle

For cases where restart isn't possible or takes too long, programmatically switch the SharePoint top navigation link from the frozen server to the alternate. This uses the Microsoft Graph API with an Azure AD app registration.

**What to figure out:**
- Do we have an existing Azure AD app registration, or do we need to create one?
- What's the SharePoint site URL?
- What permissions are needed? (Sites.ReadWrite.All or similar)
- This would live in the Admin page of Control Center as a protected manual toggle (Server A / Server B selector).

## Proposed Architecture

If all pieces come together, the flow would be:

1. **Detect** — HTTP health check fails X consecutive times
2. **Alert** — Teams notification: "DM App Server dm-prod-app2 unresponsive"
3. **Auto-remediate** — Restart JBoss service remotely
4. **Monitor recovery** — Health check confirms app is responding again
5. **Alert** — Teams notification: "DM App Server dm-prod-app2 recovered after restart"
6. **Escalate if needed** — If restart fails or app doesn't recover within timeout, alert with instruction to manually switch SharePoint link via Control Center Admin page

## Next Steps

1. Test HTTP connectivity from FA-SQLDBB to the app URL
2. Check FAC\sqlmon access to app servers (WinRM, service control)
3. Identify JBoss service name on the app servers
4. Investigate Azure AD app registration for SharePoint API access
5. Review existing Activity data from past incidents to see if patterns are detectable

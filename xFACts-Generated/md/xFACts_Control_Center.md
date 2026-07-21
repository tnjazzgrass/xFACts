# The Control Center

*The website you’re probably already using — now with an explanation*

The Control Center is the web interface that turns xFACts data into something you can actually look at without writing SQL. If you’ve ever checked a server’s memory, watched a batch process, or wondered why your Teams channel just exploded at 1:45 AM, you’ve used this. It lives at `http://fa-sqldbb:8085` and it’s always on.






What It Does

Every module in xFACts collects data, evaluates it, and stores it in the database. That’s useful, but only if someone can *see* it. The Control Center is the seeing part.

Each monitoring module has its own dedicated page. Server Health has a page. Backup Monitoring has a page. Job/Flow has a page. They don’t share screens or step on each other. You go to the page for the thing you care about, and everything about that thing is right there.

The pages are live. Most of them refresh automatically on a regular interval — some every five seconds, some every thirty, depending on how fast the underlying data changes. You don’t need to hit F5. You don’t need to click a refresh button. Open the page, and it stays current.


There are also departmental pages for teams outside of IT. Business Services, Client Relations, and Business Intelligence each have their own space with tools specific to their workflows. Same technology, different audience.







Getting Around

When you first visit the Control Center, you’ll be asked to sign in with your normal Windows credentials. Same username and password you use to log into your computer. Once you’re in, you land on the home page — a grid of cards, one per feature.

Click a card, and you’re on that feature’s page. That’s it. There’s no menu hierarchy to navigate, no breadcrumb trail to follow. Each page is self-contained. When you want something else, go back to the home page and click a different card.

The home page groups cards into sections. Monitoring pages are at the top. Departmental pages are below them. If you only have access to specific department pages, you’ll be redirected straight to yours — the home page stays out of the way.






The Things Every Page Shares

Even though each page does its own thing, they all share a few common elements.

Engine Indicators

Every monitoring page has small indicator cards near the top that represent the orchestrator processes feeding that page with data. These update in real time over a persistent connection to the server, independently of the page’s own refresh cycle.

When a process fires, its indicator changes to a blue color and displays a running message. When it finishes it displays changes color and then starts a countdown to the next run. If the last run was successful, the indicator turns green, If a process fails, the indicator turns red. If the orchestrator itself goes quiet for too long, the indicators let you know something might be wrong with the engine — not just the data.


Engine indicators are your early warning system. If the data on a page looks stale but the engine indicators are happily counting down, the data is probably just between cycles. If the engine indicators are red or frozen, something upstream may need attention.


Idle Detection

The Control Center knows when you’ve walked away. If a page detects no mouse movement or keyboard activity for a few minutes, it pauses its refresh cycle to conserve resources. When you come back, it picks right back up. There’s an overlay that lets you know it paused, so you’re never looking at stale data thinking it’s current.

Connection Awareness

If the connection to the server is interrupted — network hiccup, server restart, someone tripping over a cable — the page shows a reconnecting banner rather than just silently going stale. If the server comes back quickly, the page reconnects on its own. If it doesn’t, the banner tells you something more serious might be going on.

The Dark Theme

Yes, it’s dark mode. No, there isn’t a light mode. The decision was made early, it was made deliberately, and it will not be revisited. You’re welcome.






What the Colors Mean

Color is used consistently across every page to communicate status at a glance:

| Color | What It Means |
| --- | --- |
| **Green** | Healthy, successful, good throughput. Things are working as expected. |
| **Yellow** | Warning. Worth a look, not yet a problem. Approaching a threshold. |
| **Red** | Errors, failures, crisis. Something needs attention now. |
| **Blue** | In progress. Something is actively running or processing. |
| **White/Gray** | Informational. Neutral data with no status implication. |


These aren’t arbitrary. If something is green, it’s fine. If it’s red, go look. You don’t need to memorize a legend for every page — the language is the same everywhere.






Interactive Elements

The Control Center isn’t just a wall of numbers. Most pages have interactive elements that let you dig deeper.

**Metric cards** are the primary display unit. A number, a label, and usually a color. Many of them are clickable — click a metric and a chart slides out showing the trend over time. Want to know if today’s memory pressure is unusual? Click the PLE card and see the last 24 hours, 7 days, or 30 days.

**Slideouts** are panels that slide in from the side of the page to show detail without leaving the current view. Click an item to open its slideout, click elsewhere to close it. They’re used for execution history, file details, batch timelines — anywhere the summary needs a deeper story.

**Charts** appear inside slideouts and dedicated sections. They’re rendered client-side using Chart.js, which means they’re responsive and update in real time. Hover for exact values. Some charts support multiple time ranges.

**Tables** show up where structured data makes more sense than cards. Filter bars let you narrow down by status, type, or date range. Some tables support live filtering as new data arrives.






The Administration Page

If you see a small gear icon (&#9881;) in the top-right corner of the home page, you have access to the Administration page. If you don’t see it, you don’t — and that’s by design.

The Administration page is where the platform itself is managed. It’s the dashboard for the people who keep xFACts running, as opposed to the people who use it to keep everything *else* running.

Process Grid

Every automated process in xFACts appears as a card in the Process Grid. Each card shows the process name, its last execution status, a countdown to the next run, and daily success/failure counts. Cards are color-coded — green for success, red for failure, blue for running, gray for disabled. Click a card to see its recent execution history.

Execution Timeline

A visual canvas showing every process execution across time. Each process gets a row, and each execution is a colored bar. It’s the quickest way to answer “what happened in the last 30 minutes?” without reading a single log entry. Hover a bar for details, click it for the full story.

Platform Management

Below the timeline, a row of management tools provides access to the inner workings:

**Engine Controls** — the controls for the orchestrator engine itself. A drain mode switch lets you gracefully wind down all processes before a server restart — no new launches while currently running processes finish up. Service controls let you stop, start, or restart the orchestrator once it’s drained. These controls are deliberately restrictive. You can’t restart a running engine without draining it first.

**System Metadata** — the version tracking system. Every component in xFACts has a version history, and this tool lets you browse it, add new entries, and see the full changelog. It’s how we know what changed and when.

**Global Configuration** — the settings that control everything. Alert thresholds, polling intervals, feature flags, display preferences. Change a value here, and the next cycle picks it up. No code changes, no restarts.

**Process Scheduler** — the process registry editor. Add new processes, adjust intervals, change execution modes, configure dependency groups. Every orchestrated process can be managed here without touching a script or a database table directly.

**Documentation** — the pipeline that generates and publishes the documentation you’re reading right now. Extracts DDL reference data, builds JSON files, publishes to Confluence, pushes everything to GitHub, and exports markdown. All from a handful of toggles and a button.

**Asset Registry** — the pipeline that catalogs the platform’s own files. It scans every CSS, HTML, JavaScript, and PowerShell file, records how each one is structured, and flags anything that drifts from the platform’s format standards. It’s how the platform keeps its own house in order — run it, and you get a fresh picture of where every file stands.

**Alert Failures** — the modal showing Teams and Jira alerts that failed to deliver. When alerts exist, a red badge on the Platform Management card shows the count. This modal also allows failed alerts to be re-sent if needed.







How It’s Built

The Control Center runs on Pode, a web framework written in PowerShell. That means the same language that collects the data, processes the alerts, and runs the orchestrator is also the language that serves the web pages. One language, one team, no translation layer.

It runs as a Windows service on FA-SQLDBB via NSSM. When the server boots, the service starts. When you browse to port 8085, Pode handles the request, authenticates you against Active Directory, and serves the page. Each monitoring page has its own set of four files — a route script that builds the HTML, an API script that serves the data, a JavaScript file that handles the client-side behavior, and a CSS file for styling.

The separation is deliberate. Changing how something looks doesn’t require touching how it works. Adding a new metric to an API doesn’t require rebuilding the page layout. Each piece has one job and does it independently.


The entire Control Center — every page, every API, every stylesheet — lives in one folder on one server. There’s no build process, no deployment pipeline, no container orchestration. Update a file, restart the service, and the change is live. It’s the kind of simplicity you can only get when you’re not trying to impress anyone with your infrastructure.







Finding Help

Each monitoring module has its own documentation page right here in xFACts Secrets Revealed. Those pages explain what the module monitors, why it exists, and how it works. They’re written for a general audience — you don’t need to be technical to follow along.

For deeper technical detail — database schemas, script architecture, process flows — each module also has an Architecture page. And for the truly curious, Reference pages provide complete field definitions, DDL, and operational queries.

If something on a Control Center page doesn’t make sense or isn’t working the way you’d expect, the Applications Team is always happy to hear about it. Sometimes the answer is “it’s a known issue, we’re working on it.” Sometimes the answer is “huh, that’s a new one.” Either way, we want to know.

---

# Administration — Control Center Guide

---

# Platform Monitoring — Control Center Guide

---

## Architecture
# The Control Center Architecture

Pode & NSSM

The Control Center is a Pode web application — a web framework written entirely in PowerShell. Pode handles HTTP routing, WebSocket connections, session management, static file serving, and middleware. The same language that collects data, runs the orchestrator, and processes alerts also serves the web pages. One language, one team, no translation layer.

Pode runs as a Windows service managed by NSSM (the Non-Sucking Service Manager). When the server boots, NSSM starts PowerShell with the entry point script. When you browse to port 8085, Pode handles the request. When the service needs to restart, NSSM manages the process lifecycle.




NSSM
Windows service wrapper
Starts PowerShell on boot

→

PowerShell
Start-ControlCenter.ps1
Entry point script

→

Pode Server
HTTP + WebSocket
Port 8085

→

Browsers
AD-authenticated
Dark theme dashboards




| Component | Detail |
| --- | --- |
| Host Server | FA-SQLDBB |
| Service Name | `xFACtsControlCenter` |
| Service Account | `FAC\sqlmon` |
| Port | 8085 (HTTP + WebSocket on same port) |
| Pode Endpoints | Two: `Http` for pages/APIs, `Ws` for engine event WebSocket |
| Database Connection | `AVG-PROD-LSNR` (AG listener) via Integrated Security |
| NSSM Arguments | `-NoProfile -ExecutionPolicy Bypass -File "...\Start-ControlCenter.ps1"` |



Why Pode? The team already maintains the entire xFACts backend in PowerShell. Using a PowerShell web framework means every developer who can write a collector script can also build a dashboard page. There’s no second language to learn, no separate build toolchain, and no runtime dependency beyond what Windows Server already provides.







Folder Structure

The entire Control Center lives in a single directory tree on FA-SQLDBB. No build process, no artifact repository, no deployment pipeline. Edit a file, restart the service, and the change is live.

| Path | Purpose |
| --- | --- |
| `E:\xFACts-ControlCenter\` | Root directory |
| `scripts\Start-ControlCenter.ps1` | Entry point — server config, auth, middleware, shared routes |
| `scripts\modules\xFACts-Helpers.psm1` | Shared PowerShell module — DB access, RBAC, API cache, credentials |
| `scripts\routes\` | Route files — one `{Feature}.ps1` and one `{Feature}-API.ps1` per page |
| `public\css\` | Stylesheets — one `{feature}.css` per page, plus shared CSS |
| `public\js\` | JavaScript — one `{feature}.js` per page, plus shared JS |
| `public\images\` | Image assets |
| `public\docs\` | Documentation site (xFACts Secrets Revealed) — static HTML served by Pode |
| `logs\` | Pode request and error logs (auto-generated, file-per-day) |
| `install\` | Installation packages (Pode module, NSSM) — backup copies |



Static file serving. Four static routes are registered at startup: `/css`, `/js`, `/images`, and `/docs`. These map directly to subdirectories under `public\`. Pode serves them without authentication, so CSS and JavaScript load regardless of session state. The documentation site at `/docs` is the same static HTML that gets published to Confluence — one source, two delivery channels.







Startup Sequence

`Start-ControlCenter.ps1` is the single entry point. Everything the Control Center needs to run is initialized here, in a specific order that matters. The sequence inside the `Start-PodeServer` block:

| Order | Step | Why This Order |
| --- | --- | --- |
| 1 | Endpoints (HTTP + WebSocket) | Pode requires at least one endpoint before anything else |
| 2 | Static routes (`/css`, `/js`, `/images`, `/docs`) | Must exist before any page tries to load assets |
| 3 | File logging (requests + errors) | Logging should be active before any requests are handled |
| 4 | Session middleware | Required before authentication is configured |
| 5 | Helpers module (`xFACts-CCShared.psm1`) | Must load before auth setup — RBAC functions and `Invoke-XFActsQuery` are used in the auth scriptblock |
| 6 | AD authentication scheme | Depends on session middleware and helpers module |
| 7 | Request logging middleware + endware | After auth so user context is available in log entries |
| 8 | Login/logout routes | After auth scheme is registered |
| 9 | API cache initialization | Shared state must exist before route files try to use it |
| 10 | Engine events shared state + routes | WebSocket infrastructure before pages that depend on it |
| 11 | Shared configuration routes | The refresh interval API that every page calls on init |
| 12 | Route file loading (dot-source all `*.ps1` in `routes\`) | Last — all infrastructure must be ready before routes register |



Fatal guard. If `xFACts-CCShared.psm1` is missing, the startup script throws immediately. There is no graceful degradation — every route depends on the module for database access and RBAC. If the module isn’t there, nothing works, and failing fast with a clear error is better than silently serving broken pages.







Authentication

Every page and API endpoint requires Windows Active Directory authentication. Pode handles this natively through its form-based auth scheme, validating credentials against the `fac.local` domain.




Browser
Requests any page

→

Session?

No → Redirect to /login
Yes → Serve page


→

AD Validation
fac.local
-DirectGroups

→

Session Created
Extends on activity




| Aspect | Detail |
| --- | --- |
| Auth Scheme | Pode `Add-PodeAuthWindowsAd` with form login |
| Domain | `fac.local` |
| Session Duration | Configurable (currently 1 hour), extends on activity |
| Group Capture | `-DirectGroups` flag captures AD group membership at login |
| Login Audit | Successful logins logged to `dbo.RBAC_AuditLog` with username, groups, and client IP |
| Failed Login Detection | Endware detects POST to `/auth/login` with no authenticated user; logs as `LOGIN_FAILURE` |
| Prerequisite | RSAT-AD-PowerShell feature must be installed on the host server |


After successful authentication, user context is available in every route via `$WebEvent.Auth.User`: `Username` (AD username), `Name` (display name), and `Groups` (array of AD group names). This context feeds both the RBAC system and the request logging pipeline.


Login logging never prevents access. The auth scriptblock wraps the audit INSERT in a try/catch that silently swallows errors. If the database is unreachable at the exact moment someone logs in, they still get in — the audit record is the only thing lost.







Role-Based Access Control

The RBAC system maps Active Directory groups to platform roles, roles to page permissions, and page permissions to action grants. The entire evaluation chain runs from an in-memory cache that refreshes from the database every five minutes.




AD Groups
From login session

→

Roles
RBAC_RoleMapping
Group → Role

→

Page Tier
RBAC_PermissionMapping
view / operate / admin

→

Action Grants
RBAC_ActionGrant
Fine-grained ALLOW/DENY




Tier Hierarchy

Every page permission is assigned a tier. Higher tiers inherit all lower-tier capabilities.

| Tier | Level | Purpose |
| --- | --- | --- |
| `view` | 1 | Read-only access to the page and its data |
| `operate` | 2 | View + ability to perform actions (kill zombies, toggle processes, etc.) |
| `admin` | 3 | Operate + configuration changes, destructive actions |


Enforcement Modes

The RBAC system supports three enforcement modes, controlled by a GlobalConfig setting. This allows gradual rollout without risking lockouts.

| Mode | Behavior |
| --- | --- |
| `disabled` | All users get full access. No permission checks run. RBAC tables are loaded but ignored. |
| `audit` | Permission checks run and log results, but denials are overridden — everyone still gets in. Used for testing RBAC configuration before enforcement. |
| `enforce` | Real enforcement. Denied users see a styled 403 page; denied API actions return structured JSON errors. |


Action Permission Evaluation

For fine-grained control over specific actions (not just page access), the system evaluates grants in a strict priority order: User DENY → Role DENY → User ALLOW → Role ALLOW → Tier fallback. An explicit deny always wins, and user-level grants always override role-level grants.

Department Pages

Department-scoped roles restrict access to specific departmental pages. Users with only department roles are automatically redirected past the home page to their department’s page. The RBAC system tracks this via `department_scope` on role mappings and `RBAC_DepartmentRegistry` for route resolution.

Usage in Routes

Every page route calls `Get-UserAccess` at the top of its scriptblock. Every action API calls `Test-ActionEndpoint` (which auto-resolves the endpoint from `RBAC_ActionRegistry`) or `Test-ActionPermission` for explicit checks. UI rendering uses `Get-UserContext` to conditionally show admin controls like the gear icon.


Cache-first, fail-safe. All RBAC tables are loaded into a memory cache at startup and refreshed every five minutes. No per-request database queries. If the cache refresh fails (database briefly unreachable), stale cache data is used rather than denying everyone access. RBAC issues should never take down the Control Center.







The Four-File Pattern

Every monitoring page in the Control Center is built from exactly four files, each with one responsibility. This separation means changing how something looks never requires touching how it works, and adding a new API endpoint never requires rebuilding the page layout.

| File | Location | Responsibility |
| --- | --- | --- |
| `{Feature}.ps1` | `scripts\routes\` | Page route — builds HTML, sets up structure, links CSS/JS. Contains the RBAC access check and renders the page skeleton as a here-string. |
| `{Feature}-API.ps1` | `scripts\routes\` | API routes — all `/api/{feature}/*` endpoints that serve JSON data. Queries the database, processes results, returns structured responses. |
| `{feature}.js` | `public\js\` | Client-side behavior — data loading, DOM updates, chart rendering, timers, slideout interactions. Uses an IIFE module pattern exposing a `pageRefresh()` function. |
| `{feature}.css` | `public\css\` | Visual styling — layout, colors, typography, responsive breakpoints. Page-specific only; shared styles live in shared CSS files. |



Naming convention. Route files use PascalCase (`ServerHealth.ps1`), matching Pode’s script-loading convention. Client-side files use kebab-case (`server-health.js`), matching web conventions. The mapping is implicit by feature name, documented in each route file’s header comment.


Route File Structure

Every route file follows the same pattern: register a GET route with `-Authentication 'ADLogin'`, perform an RBAC check via `Get-UserAccess`, resolve admin context via `Get-UserContext` for the gear icon, then write the complete HTML page as a PowerShell here-string via `Write-PodeHtmlResponse`.

The HTML includes a fixed navigation bar (identical across all pages, with the current page highlighted), a header bar with title and engine indicators, section containers for data, and script tags loading the page JS followed by the shared `cc-shared.js`.

API File Structure

API files register multiple GET (and sometimes POST) routes under the `/api/{feature}/` namespace. Each endpoint authenticates via `ADLogin`, reads query parameters from `$WebEvent.Query`, executes SQL via `Invoke-XFActsQuery`, and returns JSON via `Write-PodeJsonResponse`. Error handling follows a consistent try/catch pattern that returns `{ error: "message" }` with a 500 status.

JavaScript Module Pattern

Each page’s JavaScript uses an IIFE (Immediately Invoked Function Expression) to avoid global namespace pollution. The module exposes a `pageRefresh()` function (for the manual refresh button) and registers a `DOMContentLoaded` handler that calls the page’s `init()` function. Within `init()`, the page connects to engine events, loads its GlobalConfig refresh interval, performs the initial data load, and starts auto-refresh timers.

The Home Page Exception

The Home page (`Home.ps1`) is the one departure from the four-file pattern. It’s a single route file that generates its own CSS inline — no separate JS, CSS, or API files. The home page is a static grid of navigation cards with no data loading, no refresh cycle, and no engine indicators. It doesn’t need the four-file separation because there’s nothing to separate.






The Helpers Module

`xFACts-CCShared.psm1` is the shared PowerShell module loaded at startup and available to every Pode runspace. It provides the foundation that every route file depends on.

| Function Group | Functions | Purpose |
| --- | --- | --- |
| Database | `Invoke-XFActsQuery`, `Invoke-XFActsProc` | Parameterized SQL execution against xFACts (via AG listener). Query returns hashtable arrays; Proc captures PRINT/RAISERROR messages. |
| RBAC Core | `Get-UserAccess`, `Test-ActionPermission`, `Test-ActionEndpoint`, `Get-UserContext` | Page access checks, action permission evaluation, UI rendering context |
| RBAC Internal | `Resolve-UserRoles`, `Get-UserPageTier`, `Initialize-RBACCache`, `Confirm-RBACCache`, `Write-RBACAuditLog` | Role resolution, tier comparison, cache management, audit logging |
| RBAC Response | `Get-AccessDeniedHtml`, `Get-ActionDeniedResponse` | Themed 403 pages and standardized JSON denial responses |
| API Cache | `Initialize-ApiCacheConfig`, `Get-CachedResult` | Thread-safe caching with GlobalConfig-driven TTLs via Pode shared state |
| Credentials | `Get-ServiceCredentials` | Two-tier encrypted credential retrieval from `dbo.Credentials` |
| CRS5 (Debt Manager) | `Get-CRS5Connection`, `Invoke-CRS5ReadQuery`, `Invoke-CRS5WriteQuery` | AG-aware connection strings for read (secondary) and write (primary) against `crs5_oltp` |



Why a module, not a dot-sourced file? Automation scripts that run standalone use dot-sourced `.ps1` shared files. The Control Center uses a `.psm1` module because Pode needs `Import-Module` to make functions available across all runspaces (each incoming request runs in its own runspace). A dot-sourced file would only be available in the startup runspace.







Refresh Architecture

The Refresh Architecture defines how every Control Center page keeps its data current. Every data section on every page falls into one of four categories, communicated to users via badges in section headers.

| Badge | Mode | What Triggers It |
| --- | --- | --- |
| &#9889; | Event | Data refreshes when an engine process completes (WebSocket `PROCESS_COMPLETED` event) |
| &#9679; | Live | Data refreshes on a recurring timer (GlobalConfig-driven interval) |
| &#128260; | Action | Data refreshes on user interaction (button click, filter change, server selection) |
| &#128204; | Static | Data loads once on page load and does not refresh |


Standard Page Plumbing

Every page includes the following infrastructure, even if some parts aren’t currently used. This ensures consistency and makes future additions trivial rather than requiring architectural work.

| Component | Purpose |
| --- | --- |
| `ENGINE_PROCESSES` map | Defined as a `var` before the page IIFE. Maps orchestrator process names to engine card slugs. Set to `{}` if the page has no engine cards. |
| `cc-shared.css` + `cc-shared.js` | Shared engine indicator files, linked after page-specific CSS/JS |
| `connectEngineEvents()` | Called in `init()` to establish the WebSocket connection |
| `onEngineProcessCompleted()` | Global callback for event-driven section refreshes when a process completes |
| Midnight rollover | A 60-second `setInterval` that reloads the page if the date has changed, preventing stale overnight sessions |
| GlobalConfig interval | Loaded via `/api/config/refresh-interval?page={pagename}` on init; drives the live polling timer |
| Page refresh button | Manual refresh in the header using the &#8635; character with a CSS spin animation |


Function Pattern

Pages with both event-driven and live-polling sections implement a standard set of functions: `refreshAll()` calls all load functions, `refreshEventSections()` reloads only event-driven sections, `refreshLiveSections()` reloads only timer-driven sections, `pageRefresh()` handles the manual button, and `startAutoRefresh()` starts the timer from the GlobalConfig interval.


Reference implementation. File Monitoring is the cleanest implementation of the full Refresh Architecture — all standard plumbing, a GlobalConfig interval, both event and live sections, and no exceptions. Use it as the reference when building or auditing a new page.







Engine Events (WebSocket)

Engine indicators are the real-time link between the orchestrator engine and every browser tab. They answer the question “is the data on this page current?” without requiring the user to check anything.




Orchestrator
NSSM service
Fires events on start/complete

→

POST /api/internal
localhost-only
No authentication

→

Pode State
Latest event per process
Thread-safe lockable

→

WebSocket
/engine-events
Broadcast to all tabs




Event Flow

The orchestrator sends two event types: `PROCESS_STARTED` and `PROCESS_COMPLETED`. Events arrive as JSON payloads via HTTP POST to `/api/internal/engine-event` — a route that only accepts connections from localhost (no authentication required, since only the orchestrator on the same server should be calling it). The Control Center stores the latest event per process in Pode shared state, then broadcasts to all connected WebSocket clients.

Client Bootstrap

When a browser tab opens, it calls `GET /api/engine/state` to get the current state of all processes. This REST endpoint first checks in-memory state (populated by WebSocket push events), then falls back to `ProcessRegistry + TaskLog` for processes that haven’t pushed an event since the last Control Center restart. This ensures engine indicators populate immediately rather than staying dark until the next execution.

Bar States

| State | Color | Meaning |
| --- | --- | --- |
| Idle (healthy) | Green | Completed successfully, counting down to next run |
| Running | Blue | Currently executing |
| Overdue | Yellow | Past expected interval plus 30-second grace period |
| Critical | Red | Failed, timed out, or overdue beyond twice the expected interval |
| Disabled | Gray | Process `run_mode = 0` |


Countdown and Escalation

After a successful completion, the engine card counts down `M:SS` to the next expected run. At zero, it counts up with a `+` prefix in red text. The bar stays green for a 30-second grace period, then transitions to yellow (overdue). The card frame border escalates to match — yellow border for overdue, red for critical. Each card is clickable, showing a popup with last execution details (process name, time, duration, status, output summary) without an additional API call.

Graceful Degradation

On WebSocket disconnect, the shared module auto-reconnects every three seconds and shows a subtle disconnect indicator. A configurable grace period (loaded from GlobalConfig) determines how long the reconnecting state persists before escalating to a disconnected indicator. There is no polling fallback — the connection either works or visually indicates it doesn’t.

Idle and Visibility

The engine events system respects browser tab visibility — when a tab is hidden, WebSocket processing pauses to conserve resources. Separately, an idle detection system pauses all page refresh activity after a configurable period of no user interaction, displaying an overlay when the user returns so they know the data may be stale.


All engine indicator functionality lives in two shared files. `cc-shared.js` and `cc-shared.css` handle everything: WebSocket connection, auto-reconnect, initial state hydration, card rendering, countdown timer, overdue escalation, click-to-popup, disconnect indicator, and idle detection. Never duplicate engine card code into page-specific files. If behavior needs to change, change it in the shared files — the fix propagates to every page automatically.







API Patterns

Every API endpoint follows consistent conventions that make the behavior predictable across the entire Control Center.

| Convention | Detail |
| --- | --- |
| Route namespace | `/api/{feature}/{endpoint}` — each feature owns its namespace |
| Authentication | All endpoints require `-Authentication 'ADLogin'` (except the internal engine event route) |
| Parameters | Query string for GET: `/api/endpoint?server=DM-PROD-DB`. JSON body for POST. |
| Response format | JSON always. Success returns data directly. Errors return `{ error: "message" }` with HTTP 500. |
| Database access | `Invoke-XFActsQuery` for xFACts data, `Invoke-CRS5ReadQuery`/`WriteQuery` for Debt Manager data |
| RBAC for actions | POST/PUT/DELETE endpoints call `Test-ActionEndpoint` at the top of the scriptblock. Unregistered endpoints pass through; registered ones get the full permission check. |
| Error handling | Consistent try/catch wrapping the entire scriptblock, returning structured error JSON |


The Refresh Interval Route

One shared route deserves special mention: `GET /api/config/refresh-interval?page={pagename}`. Every page calls this on init to load its live polling interval from GlobalConfig. The route looks up `refresh_{page}_seconds` in the `ControlCenter` module of GlobalConfig. If no setting exists, it returns a default of 30 seconds with a `default: true` flag so the page knows it’s using a fallback.






API Caching

Some API endpoints query external systems (like `crs5_oltp`) where data changes slowly and queries are expensive. The API cache provides a thread-safe, GlobalConfig-driven caching layer using Pode shared state.

| Aspect | Detail |
| --- | --- |
| Storage | Pode shared state (`ApiCache`) with a named lockable for thread safety across runspaces |
| TTL Resolution | Endpoint-specific setting → default setting → hardcoded fallback (600 seconds) |
| Configuration | GlobalConfig category `ApiCache.*` with settings named `cache_ttl_{cachekey}_seconds` |
| Config Refresh | TTL settings reload from GlobalConfig every 5 minutes via Pode timer |
| Force Refresh | `-ForceRefresh` switch bypasses cache; used by manual refresh buttons via `?refresh=true` |
| Thread Safety | Query execution happens *outside* the lock to avoid blocking other threads during long-running queries. Only the cache read/write is locked. |


Usage in API routes is a single function call wrapping the query: `Get-CachedResult -CacheKey 'regf_queue' -ScriptBlock { Invoke-CRS5ReadQuery -Query "SELECT ..." }`. The cache handles expiration, refresh, and thread coordination transparently.






Request Logging

Every non-static HTTP request to the Control Center is logged to `dbo.API_RequestLog` for volume analysis, performance monitoring, and capacity planning. The logging is implemented as a two-part middleware/endware pipeline.




Middleware
Captures request
start timestamp

→

Route Handler
Normal request
processing

→

Endware
Calculates duration
Logs to API_RequestLog




The middleware fires before every request, capturing the start time in `$WebEvent.Metadata`. The endware fires after every response, calculating the duration and inserting the full request record — endpoint, HTTP method, authenticated user, client IP, user agent, timestamp, duration in milliseconds, status code, response bytes, and source application.

Static asset requests (`/css/`, `/js/`, `/images/`, `/favicon.ico`) are excluded from logging — they add volume without analytical value. The endware also detects failed login attempts by checking for POST requests to `/auth/login` with no authenticated user, logging these to `RBAC_AuditLog` as `LOGIN_FAILURE` events.


Logging never breaks requests. The entire endware block is wrapped in a try/catch that silently swallows errors. If the database INSERT fails for any reason — the log entry is simply lost. The request the user was making completes normally.







Shared Client-Side Behaviors

Beyond the engine events system, several behavioral patterns are shared across all pages through convention rather than shared files. These are implemented independently in each page’s JavaScript but follow identical patterns.

Navigation Bar

Every page includes an identical horizontal navigation bar fixed at the top. Links to all pages, with the current page highlighted via an `.active` class. The admin gear icon (&#9881;) appears conditionally based on the user’s RBAC role, injected server-side in the route file. The nav bar is rendered inline in each route file’s HTML — there is no shared template system in Pode, so the nav markup is duplicated.

Idle Detection

When a page detects no mouse movement or keyboard activity for a configurable period (loaded from GlobalConfig), it pauses its refresh cycle. An overlay informs the user that data loading has been paused and invites them to click or press a key to resume. This conserves server resources and prevents unnecessary API traffic from abandoned browser tabs.

Connection Awareness

If API fetch calls fail, pages display reconnecting banners rather than silently going stale. The WebSocket system handles its own reconnection independently. Together, these provide layered connection awareness — both the data layer (API) and the event layer (WebSocket) communicate their state to the user.

Midnight Rollover

A 60-second `setInterval` on every page checks if the date has changed and reloads the page if so. This prevents stale overnight sessions where someone left a tab open and returns the next morning to yesterday’s data displayed as if it were current.

Metric Card Charts

Many metric cards are clickable, revealing trend charts rendered client-side using Chart.js. The charts support configurable time ranges (24 hours, 7 days, 30 days) and update in real time during refresh cycles. Chart instances are cached to avoid recreation on every update — data updates go through the existing chart instance.






Troubleshooting

Service Won’t Start
Check NSSM status (`nssm.exe status xFACtsControlCenter`), then the Pode error logs at `E:\xFACts-ControlCenter\logs\errors_*.log`. The most common startup failure is a missing module — if `xFACts-Helpers.psm1` isn’t at the expected path, the script throws immediately. For port conflicts, verify nothing else is using 8085. Test interactively by running `Start-ControlCenter.ps1` directly and watching the console output.

Authentication Errors
Verify the RSAT-AD-PowerShell feature is installed (`Get-WindowsFeature RSAT-AD-PowerShell`) and test AD connectivity directly (`Get-ADUser -Identity "testuser" -Server "fac.local"`). If AD validation works from PowerShell but the login page fails, check the domain FQDN in the startup script configuration.

Script Changes Not Taking Effect
Route files and the helpers module are loaded at startup and cached in memory. Changes to `.ps1` or `.psm1` files require a service restart to take effect. CSS and JavaScript changes take effect immediately but may require a browser cache clear (`Ctrl+Shift+R`) to be visible.

Engine Indicators Stuck or Dark
If engine cards never populate, check the WebSocket connection in the browser’s developer tools Network tab (look for a `/engine-events` WebSocket). If the connection is healthy but cards stay dark, the orchestrator may not be sending events — verify the orchestrator service is running and that the POST to `/api/internal/engine-event` is succeeding from localhost. If cards populated once but are now frozen, the WebSocket may have disconnected — look for the disconnect indicator in the header area.

Stale or Missing Data
Check the engine indicators first — they tell you whether the data pipeline is healthy. If indicators are green and counting down normally, the data is probably between collection cycles. If indicators are red or frozen, the issue is upstream in the orchestrator or collector scripts. For cached departmental page data, try the manual refresh button (which passes `?refresh=true` to bypass the API cache).

Static Route Errors on Startup
If Pode logs “Source path does not exist for Static Route,” ensure all directories under `public\` exist, even if empty. Pode validates static route source directories at registration time and fails if they’re missing.






How Everything Connects

The Control Center sits at the intersection of every other piece of the xFACts platform. Understanding the connections explains why the architecture is the way it is.

The Database

Every API endpoint ultimately reads from the xFACts database via the `AVG-PROD-LSNR` AG listener. The helpers module provides `Invoke-XFActsQuery` for parameterized queries and `Invoke-XFActsProc` for stored procedure execution. For Debt Manager data, separate CRS5 helper functions route reads to the secondary replica and writes to the primary, keeping heavy read queries off the production write path.

The Orchestrator

The orchestrator pushes execution events to the Control Center via the internal engine event route. This is a one-way data flow — the orchestrator tells the Control Center what happened, and the Control Center broadcasts it to browsers. The Administration page reverses this for engine controls: drain mode, service stop/start, and process enable/disable are POST requests from the browser through the Control Center to orchestrator configuration tables.

GlobalConfig

GlobalConfig drives behavior across both the backend and the frontend. Refresh intervals, idle timeouts, WebSocket grace periods, API cache TTLs, feature flags, RBAC enforcement mode, and display thresholds are all stored in GlobalConfig. The Control Center reads these via API routes and pushes them to the browser on page init. Changing a value in GlobalConfig takes effect on the next page load or the next config cache refresh — no service restart required.

The Documentation Site

The documentation you’re reading right now is served as static HTML from the Control Center’s `/docs` static route. The same HTML files are also published to Confluence via the documentation pipeline. The Control Center’s title on the Home page links directly to the documentation hub, providing a seamless bridge from “I’m using this tool” to “I want to understand this tool.”

The Module Pages

Each monitoring module builds its own complete page following the four-file pattern, but they all share the same infrastructure: the helpers module for database access, the engine events system for real-time indicators, the RBAC system for access control, and the GlobalConfig-driven refresh architecture for keeping data current. The architecture described on this page is the common foundation that every module page inherits.

| Dependency | Direction | What Flows |
| --- | --- | --- |
| xFACts Database | CC reads/writes | All monitoring data, configuration, RBAC tables, audit logs, version tracking |
| crs5_oltp Database | CC reads (secondary) / writes (primary) | Debt Manager data for batch, job flow, and departmental pages |
| Orchestrator Engine | Engine → CC | Process execution events via internal POST route |
| Active Directory | CC validates against AD | User credentials and group membership at login |
| Browser Tabs | CC → Browsers | Pages, API data, and WebSocket events |
| Documentation Pipeline | Pipeline → CC static files | Generated HTML published to `/docs` for serving |
| Asset Registry Pipeline | Pipeline → CC database | Platform file catalog and format-drift records written to `Asset_Registry` |


For the complete technical reference of every monitoring module’s database schema, scripts, and DDL, see the individual module Reference pages accessible from the documentation hub.

---

## Reference

### Deploy-xFACts.ps1

The deploy half of the inverted xFACts sync: it deploys authored content from GitHub into the live server folders. GitHub is the source of truth for authored files, and this script brings the changed authored files into their live locations. Runs in preview by default and requires -Execute to pull and copy.

**Data Flow:** Reads the GitHub Personal Access Token from dbo.Credentials via Get-ServiceCredentials (ServiceName GitHub_xFACts) and injects it into each git command as a one-shot HTTP Authorization header. Fetches the target branch of tnjazzgrass/xFACts into the server-side staging clone (E:\xFACts-Staging by default), computes the files changed between the clone HEAD and the fetched branch, maps each changed authored repository path to its live location under E:\xFACts-PowerShell, E:\xFACts-ControlCenter, or E:\xFACts-Documentation via the authored deploy map, and copies the changed files there on -Execute. Generated repository paths (xFACts-Generated/*, the manifests, repository-root files) are never copied. Launched as the Deploy Authored Content step of the Admin page pipeline modal, or run standalone.

**Staging Clone Verified, Never Created:** [sort:1] The script verifies that the staging clone (E:\xFACts-Staging by default) exists, is a git working tree, and has its origin remote pointing at tnjazzgrass/xFACts; any failed check aborts the run. It never creates, clones, or repairs the staging directory - that one-time setup is a manual operation, so the deploy path can never silently stand up a clone against the wrong remote.

**Per-Invocation Token, Never Persisted:** [sort:2] The GitHub token is retrieved from dbo.Credentials at run time and passed to each git command as a single-use HTTP Authorization header via git -c http.extraHeader. It is never written to git config, the remote URL, or any file on disk, so the credential does not persist in the staging clone between runs.

**Authored-Only Scope:** [sort:3] Deploy copies only authored files, selected through an authored deploy map that is the inverse of the generated file map in Publish-GitHubRepository.ps1. Generated repository paths (xFACts-Generated/*, the manifests) and repository-root files are classified as ignored and never copied. The two maps partition the repository so that every managed path is either authored (deployed by this script) or generated (published in the other direction), never both and never neither.


### Generate-DDLReference.ps1

Generates comprehensive JSON reference documents containing all database object metadata across the xFACts platform. Inline SQL discovers active schemas dynamically, extracts complete catalog metadata, enriches it with Object_Metadata content (descriptions, design notes, queries, status values, relationship notes), and returns multiple result sets (one per schema plus a metadata set). Uses SqlDataReader to process the result sets and writes individual JSON files per schema to the documentation data directory. These JSON files are consumed by ddl-loader.js on the reference pages to dynamically render field tables, indexes, constraints, and descriptions. Supports preview mode (default) and execute mode.

**Data Flow:** Executes inline SQL that queries the system catalog (sys.tables, sys.columns, sys.indexes, sys.check_constraints, sys.foreign_keys, sys.procedures, sys.parameters, sys.triggers, sys.objects, sys.views) and joins with dbo.Object_Metadata to produce enriched JSON. Scripts, XE Sessions, and DDL Triggers are sourced entirely from Object_Metadata. Returns one result set per schema via SqlDataReader, each written as an individual JSON file (e.g., ServerOps.json, JobFlow.json) to the documentation data directory, plus a _metadata.json with generation timestamp. These JSON files are consumed by ddl-loader.js on the reference pages.

**Preview Mode:** [sort:1] Runs in preview mode by default, showing what files would be generated without writing anything. The -Execute switch is required to actually write files. When launched from the Admin page Documentation card, -Execute is always passed.

**Dynamic Schema Discovery:** [sort:2] Schemas are not hardcoded. The SQL queries sys.schemas filtered to schemas that contain at least one user object or Object_Metadata row, excluding system schemas (sys, INFORMATION_SCHEMA, guest) and the Legacy schema. New schemas appear automatically when objects are created.

**Object_Metadata as Documentation Source:** [sort:3] All documentation content (descriptions, design notes, queries, status values, relationship notes, data flow) comes from dbo.Object_Metadata. Extended properties (MS_Description) are no longer read. Scripts, XE Sessions, and DDL Triggers are non-database objects documented solely through Object_Metadata rows.

**Multi-Result-Set Output:** [sort:4] The inline SQL returns one result set per schema, each containing SchemaName and SchemaJson columns. The script reads each with SqlDataReader.NextResult() and writes individual JSON files per schema. The final result set is a _metadata row with generation timestamp, database name, and server name.

  - **Object_Metadata**: [sort:1] Primary enrichment source. The inline SQL reads all property types (description, module, category, data_flow, design_note, query, status_value, relationship_note) for every object in each schema. Object_Metadata content is the sole source for all documentation text rendered on reference pages.
  - **Documentation Pipeline**: [sort:2] First step in the documentation pipeline. Runs before Publish-ConfluenceDocumentation.ps1 to ensure the JSON data files are current before Confluence publishing and markdown export consume them.
  - **ddl-loader.js**: [sort:3] Client-side consumer. Fetches the JSON files produced by the pipeline and renders documentation pages dynamically. The JSON structure produced by the inline SQL defines the contract that ddl-loader.js expects.


### Invoke-AssetRegistryPipeline.ps1

Asset Registry pipeline orchestrator script. Runs the selected populators (CSS, HTML, JS, PS) in parallel as independent processes, then runs the reference resolver once the populators have completed. Writes real-time per-stage status to a JSON file as each stage progresses, enabling the Admin page to poll for progress updates. On a full run, truncates the Asset Registry before launching any stage; selective runs rely on each populator clearing its own rows. Halts before the resolver if a populator fails. Launched fire-and-forget by the /api/admin/asset-registry-pipeline endpoint.


### Invoke-DocPipeline.ps1

Documentation pipeline wrapper script. Runs selected documentation steps (Generate DDL Reference, Publish to Confluence, Consolidate Upload Files) in sequence. Writes real-time status to a JSON file after each step completes, enabling the Admin page to poll for per-step progress updates. Launched fire-and-forget by the /api/admin/doc-pipeline endpoint.

**Data Flow:** Receives step selections and option flags from the Admin API endpoint. Launches each selected documentation script sequentially, capturing stdout and stderr per step. Writes real-time progress to E:\xFACts-PowerShell\Logs\doc-pipeline-status.json, which the Admin page polls every 2 seconds to display per-step status updates.

**Sequential Execution:** [sort:1] Scripts always execute in fixed order (Generate DDL, Publish Confluence, Consolidate Upload) regardless of which steps are selected. If any step returns a non-zero exit code, the pipeline halts immediately and remaining steps are not attempted. The status JSON file is updated after each step completes, enabling the Admin page to show real-time progress.

**Option Flags:** [sort:2] Accepts switch parameters that are passed through to the worker scripts: -PublishToConfluence and -ExportMarkdown control the Publish step behavior, -IncludeSQLObjects and -IncludeJSON control the Consolidate step. The wrapper does not interpret these flags — it passes them as command-line arguments to the appropriate child script.

  - **Admin Page**: [sort:1] Launched fire-and-forget by POST /api/admin/doc-pipeline when a user clicks "Run Selected" on the Documentation card. The Admin page polls GET /api/admin/doc-pipeline/status to read the status JSON and update step indicators in real time.
  - **Worker Scripts**: [sort:2] Orchestrates up to three worker scripts in fixed order: Generate-DDLReference.ps1, Publish-ConfluenceDocumentation.ps1, and Consolidate-UploadFiles.ps1. Only scripts selected by the user are executed, but ordering is always preserved.


### Publish-ConfluenceDocumentation.ps1

Publishes xFACts documentation to Confluence Server via REST API and exports markdown files for Claude context upload. Reads HTML narrative pages, architecture pages, and JSON DDL reference files, converts to Confluence Storage Format, and creates or updates pages in the target space. Authenticates via dbo.Credentials two-tier decryption with fallback to manual prompt. Also generates PlantUML ERD diagrams from JSON data for architecture pages. Supports module filtering, preview mode, and export-only mode.

**Data Flow:** Reads HTML narrative pages, architecture pages, and JSON DDL reference files from the documentation directory structure. Authenticates to Confluence Server using credentials from dbo.Credentials via two-tier decryption. Converts HTML to Confluence Storage Format and creates or updates pages in the target space via REST API, maintaining the page hierarchy. Also exports combined markdown files per module to the data\md directory for Claude project context uploads.

**Execution Modes:** [sort:1] Three modes of operation: preview mode (default) shows what would be published without making changes, -Execute publishes to Confluence and exports markdown, -ExportOnly skips Confluence publishing and only generates markdown files. Markdown export runs in all modes. Supports -Module to filter to a single module.

**Headless Execution:** [sort:2] All Invoke-WebRequest and Invoke-RestMethod calls use -UseBasicParsing to avoid the Internet Explorer engine dependency, which causes silent hangs in hidden/headless execution contexts. Credential retrieval falls back to interactive Get-Credential if dbo.Credentials lookup fails — this fallback will hang when launched headless from the Admin page.

  - **dbo.Credentials**: [sort:1] Authenticates to Confluence using the standard two-tier decryption pattern: master passphrase from dbo.GlobalConfig, service credentials from dbo.Credentials.
  - **Documentation Pipeline**: [sort:2] Second step in the documentation pipeline. Depends on Generate-DDLReference.ps1 having produced current JSON files. Output markdown files are collected by Consolidate-UploadFiles.ps1 in the third step.


### Publish-GitHubRepository.ps1

Publishes a complete snapshot of all xFACts platform files to a GitHub repository (tnjazzgrass/xFACts) via the GitHub Contents API. Collects files from server source directories, extracts SQL object definitions from the database, generates Platform Registry markdown from registry tables, compares local inventory against the current repo state via tree API, and pushes only changed files. Generates and pushes manifest.json as the final step, cataloging all files with cache-busted raw URLs for Claude session access.

**Data Flow:** Collects files from three server source directories (E:\xFACts-PowerShell, E:\xFACts-ControlCenter, E:\xFACts-Documentation) using configurable source mappings with filter and recurse options. Extracts SQL object definitions from sys.sql_modules on AVG-PROD-LSNR. Generates Platform Registry markdown by querying dbo.Module_Registry, dbo.Component_Registry, dbo.Object_Registry, and dbo.GlobalConfig. Retrieves the current repository state via the GitHub Git Trees API (recursive tree listing with blob SHAs), computes local git blob SHAs to identify creates, updates, and deletes without downloading remote content. Pushes changes via the GitHub Contents API (one commit per file). Generates and pushes manifest.json as the final step, cataloging all files with cache-busted raw URLs for Claude session access. Authenticates via PAT stored in dbo.Credentials (ServiceName: GitHub_xFACts).

**SHA-Based Diff Without Downloads:** [sort:1] Computes git blob SHA1 hashes locally using the same algorithm git uses internally (SHA1 of "blob <size>\0<content>"). Compares these against the remote tree SHAs retrieved via a single API call. This identifies exactly which files changed without downloading any remote file content, keeping API usage minimal.

**BOM Stripping:** [sort:2] Strips UTF-8 BOM (0xEF 0xBB 0xBF) from file content before computing SHAs and pushing to GitHub. PowerShell and some Windows editors add BOMs that GitHub does not expect, which would cause every file to appear as changed on every push and can trigger binary content detection.

**Managed Prefix Scoping:** [sort:3] Orphan detection (files in the repo not present locally) is scoped to four managed prefixes: xFACts-PowerShell/, xFACts-ControlCenter/, xFACts-Documentation/, xFACts-SQL/. Files outside these prefixes (such as manifest.json, README, .gitignore) are never deleted. This prevents the script from removing repo-level files it does not manage.

**Generated File Tracking:** [sort:4] SQL object definitions and Platform Registry markdown are generated at runtime rather than read from disk. These paths are tracked in a GeneratedRepoPaths list so orphan detection does not flag them for deletion — they exist only in memory during the publish run, not as files on the server file system.

**Manifest Cache-Buster Pattern:** [sort:5] Each file URL in manifest.json includes a query parameter (?v=YYYYMMDDHHMMSS) derived from the publish timestamp. This forces CDN cache misses when Claude fetches files via web_fetch, ensuring current content regardless of GitHub CDN TTL. The manifest itself requires a user-provided cache-buster when fetched at the start of a Claude session.

**Rate Limit Awareness:** [sort:6] Checks GitHub API rate limit on startup and warns if remaining calls are low. Inserts 100ms pauses between file push operations to stay within API rate limits during large pushes. The Contents API has a lower effective rate limit than the Git Data API.

  - **Documentation Pipeline**: [sort:1] Runs as a step in the Invoke-DocPipeline.ps1 pipeline, launched from the Admin page Documentation modal. Can also run standalone. When run via the pipeline, the -Execute switch is always passed.
  - **dbo.Credentials**: [sort:2] Retrieves GitHub Personal Access Token via Get-ServiceCredentials using ServiceName GitHub_xFACts. The PAT requires repo scope for Contents API access (create, update, delete files).
  - **Platform Registry Tables**: [sort:3] Queries dbo.Module_Registry, dbo.Component_Registry, dbo.Object_Registry, and dbo.GlobalConfig to generate xFACts_Platform_Registry.md as part of each publish run. This ensures the registry export in the repository always reflects the current database state.
  - **Claude Session Access**: [sort:4] The manifest.json produced by this script is the entry point for Claude to access repository content at the start of working sessions. Claude fetches the manifest to discover all file URLs, then fetches individual files on demand. The manifest must be fetched without token truncation for all URLs to be accessible.


### xFACts-DocPipelineFunctions.ps1

Shared scoped-function library for the documentation-pipeline scripts. Centralizes the user SQL object definition extraction and the Platform Registry markdown generation that the upload-consolidation and GitHub-publishing scripts previously duplicated. Dot-sourced after xFACts-OrchestratorFunctions.ps1, which supplies the Write-Log and Get-SqlData it calls.

**Data Flow:** Dot-sourced by Consolidate-UploadFiles.ps1 and Publish-GitHubRepository.ps1 after xFACts-OrchestratorFunctions.ps1. Get-SqlObjectDefinitions reads stored procedure, trigger, function, and view definitions from sys.sql_modules in the xFACts database and returns the raw rows so each consumer can write per-object .sql files. Get-RegistryExportMarkdown runs the registry export queries it holds, renders each result set as a markdown table, and returns the assembled Platform Registry markdown along with the count of tables rendered; the consumers write that markdown to a file and report the table count. The functions hold no state of their own; they read through the shared Get-SqlData against the connection target the calling script established with Initialize-XFActsScript.

**No self-import of the orchestrator:** [sort:1] As a shared-library file it declares no IMPORTS section, so it does not dot-source xFACts-OrchestratorFunctions.ps1 even though it depends on that file's Write-Log and Get-SqlData. Consuming scripts dot-source the orchestrator first, then this helper. This keeps the load order explicit at the call site and avoids a shared library reaching back into platform infrastructure.

**Markdown generator returns content and table count:** [sort:2] Get-RegistryExportMarkdown returns a hashtable carrying both the assembled markdown and the count of tables rendered, rather than the bare markdown string. The two consumers both write the markdown and report how many registry tables the snapshot covered, so the count is returned alongside the content rather than recomputed by each caller.

**Scoped to the documentation pipeline:** [sort:3] The extraction and registry-export logic was lifted into this scoped helper rather than into xFACts-OrchestratorFunctions.ps1 because only the documentation-pipeline scripts use it. Platform-wide infrastructure stays in the orchestrator; pipeline-specific shared logic lives here, next to the scripts that consume it.



# CC Session Summary 31

## 1. Session focus

Continuation of the CC File Format Initiative. This session migrated the
**JBoss Monitoring** page (component `JBoss.JBoss`, prefix `jbm`, route
`/jboss-monitoring`) — all four files refactored to the four format specs,
deployed, visually verified, and drift-cleaned to the expected end-of-migration
floor. The session also diagnosed and fixed a production query-performance
problem on the JBoss snapshot tables that surfaced during deployment (unrelated
to the migration, but caught because the migration exercised the endpoint), and
surfaced one populator-coverage question worth investigating.

The page-per-session cadence holds: JBoss is done; DBCC is the next target.

---

## 2. What was migrated — JBoss Monitoring

All four files were rebuilt to the specs and deployed:

- `JBossMonitoring.ps1` (page route)
- `JBossMonitoring-API.ps1` (API route)
- `jboss-monitoring.css`
- `jboss-monitoring.js`

### Route (`JBossMonitoring.ps1`)
- Comment-based-help header + CHANGELOG + single `ROUTE: PAGE PATH` banner.
- CCShared import shim as first statement, **absolute path**
  (`E:\xFACts-ControlCenter\scripts\modules\xFACts-CCShared.psm1`), `-Force
  -DisableNameChecking`. Page route only; API route carries no import.
- `Get-UserAccess` gate, `Get-UserContext`, then the chrome helpers
  (`Get-NavBarHtml`, `Get-PageHeaderHtml`, `Get-PageBrowserTitle`,
  `Get-ChromeBannersHtml`) into the `$html` here-string.
- Body `cc-section-platform`, `data-cc-page="jboss-monitoring"
  data-cc-prefix="jbm"`. Section is shared `cc-section cc-fill`.
- Engine card: process `Collect-JBossMetrics`, slug `jboss`, label `JBOSS`,
  run_mode 1 (live; no engine-card drift).
- Section refresh badge `cc-refresh-badge-event` (yellow lightning).
- Two overlays (`jbm-modal-info`, `jbm-modal-switch`) as
  `cc-modal-overlay cc-hidden` / `cc-dialog cc-dialog-modal`, backdrop-close
  wired via `data-action-click`. Both start hidden via `cc-hidden`.
- Single `<script src="/js/cc-shared.js">`.

### API (`JBossMonitoring-API.ps1`)
- CBH header + single `ROUTE: API ENDPOINTS` banner (no CHANGELOG — forbidden
  in api-route files).
- Four endpoints: `status` (GET), `queue-status` (GET), `active-server` (GET,
  returns `CanSwitch=[bool]$ctx.IsAdmin`), `switch-server` (POST).
- `Test-ActionEndpoint` is the first line of every endpoint.
- `switch-server` audit insert uses the platform convention:
  `$user = "FAC\$($WebEvent.Auth.User.Username)"`, via `Invoke-XFActsNonQuery`
  into ActionAuditLog `(page_route, action_type, action_summary, result,
  executed_by)`, own try/catch.
- Admin gate is server-side: `active-server` returns `CanSwitch`; `switch-server`
  keeps its inline `$ctx.IsAdmin` 403 (after the `Test-ActionEndpoint` hook).

### CSS (`jboss-monitoring.css`)
- 1 LAYOUT + content banners, ~110 base classes, all `jbm-` prefixed, all
  selectors flattened to state-on-element classes (no descendant/combinator/
  stacked-pseudo selectors). Queue table fully class-based
  (`jbm-qtable`/`jbm-q-th`/`jbm-q-row`/`jbm-q-cell`/`jbm-q-name`/`jbm-q-num`).
- Deliberate literals kept (token-vs-literal calls all upheld by the populator):
  `#6a7a8a`, `#4ade80`, `#ef4444`, the rgba status tints, and the
  card-warning/critical 0.03-alpha backgrounds.

### JS (`jboss-monitoring.js`)
- Section order: CONSTANTS (ENGINE PROCESSES `var jbm_ENGINE_PROCESSES`, ACTION
  DISPATCH `jbm_clickActions`, DELTA FIELDS, INFO CONTENT) → STATE → FUNCTIONS:
  INITIALIZATION (`jbm_init` only) → FUNCTIONS: ACTION DISPATCH
  (`jbm_dispatchClick`) → work functions → FUNCTIONS: PAGE LIFECYCLE HOOKS
  (last; the three hooks only).
- Migrated to the `cc-shared.js` bootloader contract: bootloader injects the
  module and calls `jbm_init`; `jbm_init` registers the delegated body click
  listener, calls `cc_connectEngineEvents()`, and loads data. No
  `DOMContentLoaded`, no self-wired engine cards.
- Shared-call renames: `engineFetch`→`cc_engineFetch`, `escapeHtml`→
  `cc_escapeHtml`, `showConfirm`→`cc_showConfirm` (danger class
  `cc-dialog-btn-danger`). Page-local formatters (`jbm_fmtN`/`jbm_fmtC`/
  `jbm_formatBytes`/`jbm_formatUptime`/`jbm_fmtDelta`/`jbm_fmtCumulative`) kept
  local — no shared equivalent.
- All inline `onclick` → `data-action-click="jbm-*"` + `data-action-jbm-*`
  argument attributes, routed through `jbm_clickActions`. `window.isAdmin`
  removed; clickable Users badge gates on `jbm_canSwitch` (seeded from the API
  `CanSwitch` flag).
- Hooks: `jbm_onPageRefresh`, `jbm_onPageResumed`,
  `jbm_onEngineProcessCompleted`.
- Static-modal pattern (`cc-hidden` toggle, `(target, event)` close handlers
  with backdrop guard).

Byte discipline on all four (and on every redelivery): no BOM, pure ASCII,
CRLF, single trailing newline (CSS/JS exactly one; PS no special trailing rule).

---

## 3. Final drift state (post-fix)

| file | TotalRows | Compliant | NonCompliant |
|---|---|---|---|
| jboss-monitoring.css | 353 | 353 | 0 |
| jboss-monitoring.js | 311 | 311 | 0 |
| JBossMonitoring-API.ps1 | 72 | 72 | 0 |
| JBossMonitoring.ps1 | 153 | 151 | **2** |

(Pre-refactor was 160 / 179 / 8 / 106 non-compliant respectively.)

The 2 residual route rows are the **expected end-of-migration transitional
rows**, identical to every migrated page:
- `MISPLACED_IMPORT` — the CCShared import shim sits in the ROUTE section.
- `MISSING_RBAC_CHECK_PAGE` — `Get-UserAccess` is not literally the first
  statement because the shim precedes it.

Both clear platform-wide when the shim is removed at end-of-migration (when
`Start-ControlCenter.ps1` loads CCShared at startup and `xFACts-Helpers.psm1`
is deleted). No action needed per-page.

---

## 4. Deployment issues caught and fixed (live, this session)

These were found by deploying and exercising the page — the populators do not
catch them. Reinforces the deploy-and-eyeball step.

### 4.1 Page 500 — `$PSScriptRoot` in the import shim
The route initially 500'd on load. Cause: the CCShared import used
`"$PSScriptRoot\modules\..."`, but Pode runs route scriptblocks in a runspace
where `$PSScriptRoot` is empty, so the path was invalid and `Import-Module`
threw. **Fix: absolute path**, matching the deployed DmOperations route. The PS
spec shows the `$PSScriptRoot` form as valid syntax, but the running platform
requires the absolute path — match the deployed convention, not the spec's
illustrative example.

### 4.2 Queue sections missing — query timeout (NOT a migration bug)
The queue accordion sections didn't render. Root cause: the `queue-status`
endpoint returned HTTP 500 with **"Execution Timeout Expired"** on `Fill` — the
query exceeded the 30s command timeout. The SQL was byte-identical to the
pre-migration original; the table had simply grown past the point the
full-history scan could complete in 30s.

`JBoss.QueueSnapshot`: **4,227,264 rows / 78,300 distinct cycles**, 2026-03-08
to 2026-06-04. Indexes: `IX_QueueSnapshot_Retention (collected_dttm)`,
`IX_QueueSnapshot_ServerQueue (server_id, queue_name, collected_dttm DESC)`,
`PK_QueueSnapshot (queue_snapshot_id)`.

The query was ranking all 78,300 historical cycles (full-table window-function
scan) plus a per-row correlated subquery, just to find each server's latest two
cycles.

**Fix (applied to `queue-status` AND preemptively to `status`):**
- Added a **24-hour lookback floor** (`WHERE collected_dttm >= DATEADD(HOUR,
  -24, GETDATE())`) to the cycle-finding CTE so it ranks a small recent slice
  that seeks off the `collected_dttm` index instead of full history.
- In `queue-status`, replaced the per-row correlated subquery with a
  materialized `PrevCycle` CTE (rank-2 timestamp per server) joined directly;
  the prev-snapshot join keys on `(server_id, queue_name, collected_dttm)`,
  matching `IX_QueueSnapshot_ServerQueue`.
- Per-server partitioned ranking preserved (a global top-2 would be wrong — the
  three servers have independent cycle timestamps).
- Output shapes byte-identical; JS unchanged.

**24h chosen over 6h** deliberately: the page exists to catch frozen servers, so
the window doubles as "how long a silent server stays visible." 24h keeps a
server that died overnight visible the next morning, at negligible extra scan
cost (low thousands of rows either way vs. 4.2M before). Value is a **documented
inline constant** in both queries, not GlobalConfig — see decision in §6.

### 4.3 Info-icon drift fix (post-deploy drift cleanup)
The first-pass route drift had 4 rows: the 2 transitional + 2 real:
- `MALFORMED_PAGE_SHELL_WHITESPACE` — `<head>` needs exactly one blank line
  between `<title>`→page-CSS link and between the two `<link>` tags. Added.
- `ACTION_ON_NON_INTERACTIVE_ELEMENT` — the section-header info icon was a
  `<span>` carrying `data-action-click`. HTML spec §7.5 closes the
  action-carrier list to interactive elements + overlay containers. **Fix:
  convert to `<button type="button">`** (established convention; confirmed
  against Apps/Integration's button-reset pattern: explicitly set `background`,
  `border`, `font-family: inherit`, `padding: 0`, `cursor`). Applied to the
  route's static icon AND all six JS-rendered mini-card icons for consistency
  (the JS ones don't flag — the HTML populator doesn't parse JS strings — but
  the pattern must match). Added the two button-reset properties to
  `.jbm-info-icon` and removed the dead, never-referenced `.jbm-section-info-icon`
  rule + its hover.

---

## 5. Radar items raised this session (for investigation)

### 5.1 Populator coverage gap — FORBIDDEN_FUNCTION_IN_API_ROUTE (MEDIUM)
`JBossMonitoring-API.ps1` defines functions inside route scriptblocks: the four
DBNull cleaners (`cv`/`ci`/`cl`/`cd`) in the `status` endpoint, and four
firewall/SharePoint helpers (`Invoke-PaloAltoAPI`, `Set-FirewallRule`,
`Get-SharePointAccessToken`, `Update-SharePointNavNode`) in `switch-server`.
These were expected to flag `FORBIDDEN_FUNCTION_IN_API_ROUTE`, but the populator
reported **0** such rows.

Two possibilities, to be resolved (not assumed):
1. The rule/populator under-reports — if the PS spec intends these as
   violations, the populator (or the rule wording) needs adjustment.
2. The rule was never meant to flag these — in which case the prior
   "accepted transitional drift" framing of these helpers was wrong, and there
   is no gap.

Action: check the PS spec rule definition against the populator's detection
logic for in-route-scriptblock function declarations. Reproducible via the two
endpoints above. Not a crisis; a catalog-trust item.

### 5.2 No retention on platform snapshot tables (LOW/FUTURE)
There is no retention/purge on any platform table. `JBoss.QueueSnapshot`
(4.2M rows) and `JBoss.Snapshot` grow unbounded. The 24h query floor (§4.2)
stops the queries from caring about old rows but does not stop accumulation;
storage, populators, and any future full-history query will eventually feel it.
The `IX_QueueSnapshot_Retention` index name implies retention was intended.
Other CC pages with the same full-history-ranking pattern against their own
snapshot tables (Server Health, Platform Monitoring, etc.) will hit the same
timeout wall as their tables grow — apply the same lookback-floor treatment when
migrating them, and consider a platform-wide retention strategy as a separate
initiative.

---

## 6. Decisions locked this session

- **Query lookback = 24h, hardcoded as a documented inline constant**, not
  GlobalConfig. Reasoning: it is a performance pre-filter implementation detail,
  not a business knob; configurability adds a failure surface (we just debugged
  a 500) for flexibility unlikely to be used; the "tune it on the fly in an
  emergency" benefit is illusory because the real fix in that scenario
  (retention/index) is a deploy anyway. Per-request GlobalConfig read (Option A)
  was considered and rejected along with caching (Option B).
- **Import shim uses absolute path**, never `$PSScriptRoot`, in Pode route
  scriptblocks. Match the deployed convention.
- **Info icons are `<button type="button">`** platform-wide (route + JS), with
  the button-reset on the icon class. This is the standing fix for
  `ACTION_ON_NON_INTERACTIVE_ELEMENT` on info icons.

---

## 7. CC File Format Initiative — overall status

- JBoss Monitoring migrated (this session). Previously migrated: all
  orchestration-outlier pages (DM Operations last), all departmental pages, all
  Server Operations pages, plus Replication Monitoring, Index Maintenance,
  Backup, Applications & Integration.
- Going-forward cadence: one page per session. Remaining pages (~18) are full
  refactors against the four specs directly.
- The transitional per-page import shim (page routes only) produces the 2 known
  drift rows that clear at end-of-migration.
- Helper-module consolidation (delete `xFACts-Helpers.psm1`, remove transitional
  `Import-Module` lines, update `Start-ControlCenter.ps1` to load CCShared at
  startup, delete `engine-events.css`/`engine-events.js`) cannot happen until
  all remaining CC pages are migrated.

---

## 8. Carry-forward (open items)

Carried from Session 29/30 and still open, plus items added this session.

### Page migration (primary thread)
- **8.1 — Next CC page: DBCC** (selected for next session). All remaining pages
  are full refactors against the four specs.
- **8.2 — Apply the §4.2 lookback-floor treatment** to any migrated page whose
  endpoints rank full snapshot history (watch Server Health, Platform
  Monitoring especially).

### DM Operations (from Session 29/30, still open)
- **8.3 — `RBAC_ActionRegistry` rows for DM Operations launch/abort endpoints.**
  Currently admin-hidden via UI; needs server-side enforcement rows. (DB
  hardening.)
- **8.4 — Archive launch not yet tested** (Shell Purge launch confirmed working
  on live system; Archive deferred).

### JBoss (from this session)
- **8.5 — `RBAC_ActionRegistry` row for the JBoss `switch-server` endpoint**
  (server-side admin hardening; currently inline `$ctx.IsAdmin` 403 only).

### Populator / pipeline
- **8.6 — Investigate FORBIDDEN_FUNCTION_IN_API_ROUTE coverage** (§5.1).
- **8.7 — JS populator performance** (sub-phase instrumentation, no-op-walk
  timing experiment; obvious optimizations already netted nothing; PowerShell
  per-statement interpretation suspected as the floor). Full-pipeline wall-clock
  baseline ~4:51, gated almost entirely by the JS populator.
- **8.8 — Admin pipeline UI** (incremental per-stage status reporting → Admin
  API endpoints → Admin modal/tile). Co-equal priority with page refactoring.

### Platform / backlog
- **8.9 — Retention strategy for snapshot tables** (§5.2; no retention anywhere
  on the platform today).
- **8.10 — DBCC backlog: disk alert suppression during CHECKDB runs**
  (medium; cross-component awareness so disk alerts are suppressed/annotated
  while CHECKDB is actively running). Note this is the JBoss-page-adjacent
  monitoring concern, distinct from the DBCC *page* migration in 8.1.

---

## 9. Session boot sequence (next session)

1. Read the instructions, then this summary (CC_Session_Summary_31).
2. Verify anchor docs in Project Knowledge via `project_knowledge_search`:
   active planning doc + Development Guidelines + Backlog + Platform Registry.
3. Next target is **DBCC** (§8.1). Request a cache-busting value for the root
   `manifest.json`, fetch the CC app sub-manifest, then fetch the four current
   DBCC files (route, API, css, js) plus the four specs as needed.
4. Build order per page: route → API → CSS → JS, one complete drop-in file at a
   time, exact production filenames, byte discipline throughout.
5. Sessions are not scoped to the carry-forward list — once DBCC is done,
   continue to the next item by-ear (another page, or the pipeline UI / populator
   investigation). Nothing is deferred unless context limits force it.

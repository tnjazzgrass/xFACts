# CC Session Summary 35 — Batch Monitoring Page Migration

## 1. Session focus

CC File Format Initiative, page migration thread. Target: the **Batch
Monitoring** page (component `BatchOps`, cc_prefix `bat`, route
`/batch-monitoring`, slug `batch-monitoring`, body section
`cc-section-platform`). All four files refactored to the four CC specs,
deployed, visually verified, and drift-cleaned to the expected
end-of-migration floor.

Batch Monitoring was the confirmed next target from the Session 34 close. The
page-per-session cadence holds: Batch Monitoring is done; the next page
(Server Health) is selected for next session — the last platform page on the
list, and the largest/most complex remaining.

---

## 2. What was delivered

Four full drop-in replacements, exact production filenames, byte-disciplined
(pure ASCII, no BOM, PS + CSS CRLF, JS LF, single trailing newline):

- `BatchMonitoring.ps1` — page route (~203 lines)
- `BatchMonitoring-API.ps1` — API route, 6 read-only GET endpoints (~600 lines)
- `batch-monitoring.css` — page styles (~1050 lines)
- `batch-monitoring.js` — page module (~1512 lines)

Build order held: route → API → CSS → JS. Four engine cards in
`Orchestrator.ProcessRegistry` cc_sort_order: NB (slug `nb`, sort 1), PMT
(slug `pmt`, sort 2), BDL (slug `bdl`, sort 3), SUMMARY (slug `summary`,
sort 4). Processes: `Collect-NBBatchStatus`, `Collect-PMTBatchStatus`,
`Collect-BDLBatchStatus`, `Send-OpenBatchSummary`. All four run_mode 1
(live), so no engine-card registry drift expected (contrast DM Operations,
which carried 3 engine-card rows for not-yet-live processes).

### Refactor highlights

**Route.** Comment-based-help header + CHANGELOG + single `ROUTE: PAGE PATH`
banner. CCShared import shim as first statement *inside* the route scriptblock
(absolute path, `-Force -DisableNameChecking`); page route only, API route
carries no import. `Get-UserAccess` gate, chrome helpers, `$bannerHtml`. Body
`cc-section-platform` / `data-cc-page="batch-monitoring"` /
`data-cc-prefix="bat"`. Four engine cards using the shared
`cc-card-engine-<slug>` / `cc-engine-bar-<slug>` / `cc-engine-cd-<slug>` ids;
engine bars emitted empty (no extra class). One overlay construct: the batch
detail slideout (`id="bat-slideout-detail"`, `cc-slide-overlay` /
`cc-dialog cc-dialog-slide cc-xwide`), backdrop-close wired via
`data-action-click="bat-close-slideout"` on both the overlay and the X.
Two-column grid layout (`bat-grid-layout` / `bat-grid-column`): left column
Today's Activity + Active Batches; right column Process Status + Batch History.

**API.** Six read-only GET endpoints: `process-status`, `active-batches`,
`daily-summary`, `history`, `history-month`, `history-day`. Every endpoint
calls `Test-ActionEndpoint` first (`if ((Test-ActionEndpoint -WebEvent
$WebEvent) -eq $false) { return }`); every endpoint ends
`Write-PodeJsonResponse`. Single `ROUTE: API ENDPOINTS` banner; no CHANGELOG
(forbidden in api-route); no inline `# ===` banners; no `Write-Host`. All SQL
here-strings carried verbatim (this page reads NB/PMT/BDL batch status and
history from Debt Manager reference tables). No write endpoints — so no `FAC\`
username-prefix work and no RBAC write-endpoint follow-ups for this page.

**CSS.** 283 → ~509 catalogued rows (the row count rises because the refactor
splits compound/state constructs into the standalone-token + compound form the
spec requires; non-compliant went 253 → 0). All chrome/overlay/modal/slideout
shells deleted (now shared). Slideout summary/stat/section mapped to shared
`cc-slide-*`; the three page section tables (`bat-active-batch-table`,
`bat-month-summary-table`, `bat-day-table`) kept page-local per the hybrid
decision (they differ from shared `cc-slide-table-*` in padding/fonts; mapping
them would change appearance — that consolidation is a later chrome phase).
Loading/empty states kept page-local (`bat-loading`, `bat-no-activity`). All
forbidden selectors flattened to state-on-element; all reprefixed `bat-`;
literals tokenized only on exact match. The three card accent-border tints
(`rgba(86,156,214,0.4)` NB / `rgba(197,134,192,0.4)` PMT /
`rgba(206,145,120,0.4)` BDL) stayed literal — no exact tokens — kept
page-local intentionally.

**JS.** 558 → ~556 catalogued (non-compliant 299 → 0). Migrated to the
`cc-shared.js` bootloader contract: bootloader reads `data-cc-prefix`, calls
`bat_init`; `bat_init` registers one delegated body click listener routing
`bat-*` actions through `bat_clickActions`, calls `cc_connectEngineEvents()`,
starts the live + midnight-rollover timers, and loads all sections.
Shared-call adoption: `cc_engineFetch`, `cc_escapeHtml`, `cc_safeInt`,
`cc_safeFloat`, `cc_formatTimeOfDay`, `cc_formatTimeSince`, `cc_formatAge`,
`cc_MONTH_NAMES`, `cc_DAY_NAMES`, `cc_connectEngineEvents`. Page-local helpers
kept (no shared equivalent): `bat_formatDurationMinutes`,
`bat_formatDisplayDate`, `bat_parseDateOnly`. All `onclick` → `data-action-click`
+ `data-bat-*` argument attributes; all routing via the `bat_clickActions`
dispatch table. Slideout open/close per the JS spec §11.5.3 static
slide-overlay pattern (add `cc-open` to overlay then inner dialog via
`requestAnimationFrame`; close via one-shot `transitionend`; `(target, event)`
backdrop guard). Hooks: `bat_onPageRefresh`, `bat_onPageResumed`,
`bat_onSessionExpired` (stops live polling), `bat_onEngineProcessCompleted`
(refreshes event-driven sections).

### Live-polling architecture (design decision)

The page keeps a page-local live timer (`bat_livePollingTimer`) for the Active
Batches section, fired on the GlobalConfig cadence
(`/api/config/refresh-interval?page=batch`), with all gating delegated to
`cc_engineFetch` — which self-gates (returns null) when the tab is hidden,
the session is expired, or polling is idle-paused. The old manual hidden/expired
gating is gone; the page only owns the cadence, the shared layer owns the gate.
The midnight-rollover full reload (`bat_autoRefreshTimer`) is genuinely
page-specific and stays page-local. Event-driven sections (Today's Activity,
Process Status, Batch History) refresh on `onEngineProcessCompleted`.

---

## 3. Visual verification

Clean on the first deployed pass — no visual differences from the pre-refactor
state, all sections rendering and functioning as expected (engine cards, live
Active Batches table with per-row progress bars / status labels, the
year/month/day history tree, and the day-detail slideout with its tab/filter
bars and expandable per-batch rows). No live-only bugs surfaced (contrast DM
Operations' accordion-default-open and tandem-column-growth bugs, or Job Flow's
five diagnostic rounds).

---

## 4. Final drift state

Pre-refactor non-compliant counts were 253 / 299 / 7 / 115 (css / js / api /
route).

| File | Total | Compliant | Non-compliant |
|---|---|---|---|
| batch-monitoring.css | 509 | 509 | **0** |
| batch-monitoring.js | ~555 | ~555 | **0** |
| BatchMonitoring-API.ps1 | 84 | 84 | **0** |
| BatchMonitoring.ps1 | ~173 | ~171 | 2 (expected) |

The 2 page-route rows are the known end-of-migration transitional pair, not
file defects:
- **Import shim (2):** `MISPLACED_IMPORT` + `MISSING_RBAC_CHECK_PAGE` — the
  transitional `Import-Module xFACts-CCShared.psm1` as the first statement
  inside the route scriptblock (so `Get-UserAccess` isn't literally first).
  Clears platform-wide when `Start-ControlCenter.ps1` loads CCShared at startup
  and the shim line is removed at end-of-migration.

### Real conformance drift fixed this session (post-deploy pass, → 0)

The first post-deploy drift report surfaced five real rows beyond the expected
two; all five were fixed:

- **JS — `JS_CSS_CLASS_UNRESOLVED` on `bat-month-details-row`** (1 row). The
  history-tree month-detail `<tr>` carried a class with no CSS definition and no
  JS selector (the row is targeted only by its `id`, `bat-month-row-<key>`).
  Removed the dead class; the `id` stays. (Dead-code-removal rule: an
  unreferenced, unstyled class is dead, not a missing definition to invent.)
- **API — `TRAILING_WHITESPACE`** (1 row, lines 101/103/137/139/142). Trailing
  spaces sat *before* the CRLF inside SQL here-strings (a space then `\r`).
  Stripped the trailing whitespace while preserving CRLF; SQL text unchanged.
  (Note: a naive `grep ' $'` misses these because the `\r` sits between the
  space and the line end — the correct check is `[ \t]+\r$`.)
- **Route — `BANNER_MALFORMED_TITLE_LINE` + `FILE_ORG_MISMATCH`** (2 rows, both
  fixed by one correction). The CHANGELOG banner title was the bare word
  `CHANGELOG`; the spec (§3.1 + §4.4) requires every banner title to parse as
  `<TYPE>: <NAME>`, and CHANGELOG's fixed singleton NAME is
  `CHANGELOG: CHANGE HISTORY`. Retitled the banner and matched the FILE
  ORGANIZATION list entry to it verbatim. (Both spots must carry the full
  `<TYPE>: <NAME>` — the FILE ORG list lists banner titles verbatim, in order.)
- **Route — `MISSING_SHARED_SCRIPT_TAG`** (1 row). See §5; resolved by inlining
  the literal `<script>` tag.

Baseline → final non-compliant: css 253→0, js 299→0, api 7→0, route 115→2-expected.

---

## 5. Script-tag pattern decision (spec-governed)

The page initially emitted the bootloader script tag via
`$scriptHtml = Get-PageScriptTagHtml` (a helper in the deprecated
`xFACts-Helpers.psm1` returning the literal
`<script src="/js/cc-shared.js"></script>`). The HTML populator scans markup as
text and cannot resolve a PowerShell variable substitution, so it saw zero
`<script>` tags in the page and fired `MISSING_SHARED_SCRIPT_TAG`.

The helper indirection was an earlier design convenience (one SHARED-scope
catalog row instead of one per page), but the HTML spec (§1.1, §3.2, §3.2.1) is
explicit: the literal `<script src="/js/cc-shared.js"></script>` tag is the last
content in `<body>` before `</body>`. The spec is the sole authority and files
conform to the spec, not the reverse — a design preference the spec does not
encode does not override it. Resolution: **inline the literal tag** and drop the
`$scriptHtml` helper call. Cost is benign — one LOCAL `JS_FILE USAGE` row per
page that resolves correctly against the `cc-shared.js` definition; benefit is
zero drift and one fewer dependency on the deprecated Helpers module.

**Platform consistency note (carry-forward):** if the intent is for *all* pages
to inline the literal tag (the spec-correct, zero-drift path), the remaining and
already-migrated pages should follow suit, and `Get-PageScriptTagHtml` itself
becomes dead code to retire alongside the Helpers cleanup. Confirm the direction
before the next page so the whole set stays consistent. (See §8.x.)

---

## 6. Lessons reinforced this session

- **Every banner title is `<TYPE>: <NAME>`** (§3.1); singletons use the fixed
  NAMEs from §4.4 (`CHANGELOG: CHANGE HISTORY`, `ROUTE: PAGE PATH`, etc.). A
  bare `CHANGELOG` title fails `BANNER_MALFORMED_TITLE_LINE`, and the mismatch
  cascades to `FILE_ORG_MISMATCH` because the FILE ORGANIZATION list must list
  the full banner titles verbatim, in order.
- **The spec governs even established conveniences.** The script-tag helper was a
  deliberate prior choice, but the spec mandates the literal inline tag. When a
  design pattern and the spec disagree, the spec wins; conform the file.
- **Trailing whitespace hides behind CRLF.** A space before `\r` is real trailing
  whitespace the populator flags, but `grep ' $'` misses it. Use `[ \t]+\r$`.
  Strip it without disturbing CRLF or the SQL text.
- **A class with no CSS and no JS selector is dead code, not a missing
  definition.** Remove it rather than inventing a rule to satisfy the reference
  (the `bat-month-details-row` case — the row is keyed by `id`).
- **`cc_engineFetch` self-gates.** A page-local live timer needs only to own the
  cadence; hidden/idle/expired gating is handled by the shared fetch returning
  null. No need to re-read the shared gate flags page-side.
- **`cc_DAY_NAMES` is 1-indexed** (keyed by SQL DATEPART dw, 1=Sun..7=Sat), so
  `cc_DAY_NAMES[getDay() + 1]` — the +1 corrects for JS's 0-indexed `getDay()`.
  (The old page used a 0-indexed local array; the shared lookup needs the offset.)
- **Migrating markup ≠ validating it.** The bare CHANGELOG title and the
  `$scriptHtml` indirection were both carried forward from prior authoring; the
  drift pass, not the eyeball, caught them. The original file is not authority;
  the spec is.

---

## 7. CC File Format Initiative — overall status

- Batch Monitoring migrated (this session). Previously migrated: Job Flow, File
  Monitoring, DBCC Operations, JBoss, all orchestration-outlier pages (DM
  Operations last), all departmental pages, all Server Operations pages, plus
  Replication, Index Maintenance, Backup, Applications & Integration.
- Going-forward cadence: one page per session. **Server Health is the last
  platform page on the list** — the largest and most complex remaining page.
  After it, the platform pages are exhausted (any remaining real-drift pages —
  e.g. Admin, BDL Import — are tracked separately).
- Transitional per-page import shim (page routes only) produces the 2 known
  route drift rows that clear at end-of-migration.
- Helper-module consolidation (delete `xFACts-Helpers.psm1`, remove transitional
  `Import-Module` lines, update `Start-ControlCenter.ps1` to load CCShared at
  startup, delete `engine-events.css`/`engine-events.js`) cannot happen until all
  remaining CC pages are migrated. The script-tag inlining decision (§5) feeds
  this: retiring `Get-PageScriptTagHtml` belongs to the same cleanup.

---

## 8. Carry-forward (open items)

### Page migration (primary thread)
- **8.1 — Next CC page: Server Health** (selected for next session). The last
  platform page on the list; largest and most complex. Full refactor against the
  four specs. Apply the §4.2 lookback-floor treatment to any endpoint that ranks
  full snapshot history (Server Health flagged as a watch case in S31).

### Batch Monitoring (from this session)
- **8.2 — Script-tag pattern, platform-wide.** Decide whether all pages inline the
  literal `<script src="/js/cc-shared.js"></script>` tag (spec-correct, zero
  drift) and retire `Get-PageScriptTagHtml`. Confirm before the next page so the
  set stays consistent. (No Batch-specific RBAC follow-up — the API is read-only.)
- **8.3 — Chrome-consolidation candidate:** Batch's three page-local section
  tables (`bat-active-batch-table`, `bat-month-summary-table`, `bat-day-table`)
  join the outlier list to promote to shared section-table chrome when that phase
  lands.

### Carried from prior sessions (still open)
- **8.4 — `RBAC_ActionRegistry` rows for Job Flow write endpoints** (S34:
  `app-tasks/toggle`, `app-tasks/batch`, `configsync/save`).
- **8.5 — Job Flow section-load-failure presentation** (S34; `cc_showAlert` modal
  vs. non-blocking inline for background loads). Minor, behavior-only.
- **8.6 — `RBAC_ActionRegistry` rows for File Monitoring write endpoints** (S33).
- **8.7 — `RBAC_ActionRegistry` rows for DM Operations launch/abort endpoints**
  (S29/30).
- **8.8 — Archive launch not yet tested** (S29/30; Shell Purge confirmed live).
- **8.9 — `RBAC_ActionRegistry` row for JBoss `switch-server`** (S31).
- **8.10 — `RBAC_ActionRegistry` rows for DBCC launch/abort endpoints** (S32).
- **8.11 — JS populator performance** (sub-phase instrumentation; PowerShell
  per-statement interpretation suspected as the floor; full-pipeline baseline
  ~4:51, gated by the JS populator).
- **8.12 — Admin pipeline UI** (incremental per-stage status → Admin API endpoints
  → Admin modal/tile). Co-equal priority with page refactoring.
- **8.13 — Retention strategy for snapshot tables** (none platform-wide).
- **8.14 — DBCC backlog: disk alert suppression during CHECKDB runs** (medium;
  cross-component awareness so disk alerts are suppressed/annotated while CHECKDB
  is actively running).
- **8.15 — 4th overlay construct (shared slide-up dock).** Pages with a slide-up
  panel keep it page-local until the shared construct exists.
- **8.16 — Chrome-consolidation phase.** Establish shared section-table chrome,
  then map the outlier page-local section tables (Job Flow's and Batch
  Monitoring's among them) to it. Later phase.

---

## 9. Session boot sequence (next session)

1. Read the instructions, then this summary (CC_Session_Summary_35).
2. Verify anchor docs in Project Knowledge via `project_knowledge_search`:
   active planning doc + Development Guidelines + Backlog + Platform Registry.
3. Next target is **Server Health** (§8.1) — the last and most complex platform
   page. Request a cache-busting value for the root `manifest.json`, fetch the CC
   app sub-manifest, then fetch the four current Server Health files (route, API,
   css, js) plus the four specs as needed. Given the page's size, budget for a
   long session and watch context; fall back to file uploads if
   `raw.githubusercontent.com` rate-limits (account-scoped — never retry).
4. Build order per page: route → API → CSS → JS, one complete drop-in file at a
   time, exact production filenames, byte discipline throughout (PS + CSS CRLF,
   JS LF, no BOM, pure ASCII, single trailing newline).
5. Before emitting any call to a CCShared wrapper or shared class/utility, verify
   its actual signature/definition against `xFACts-CCShared.psm1` / `cc-shared.css`
   first.
6. Resolve the script-tag platform decision (§8.2) before or at the start of
   Server Health so it lands consistently.
7. Sessions are not scoped to the carry-forward list — once Server Health is done,
   continue to the next item by-ear (the remaining real-drift pages, the pipeline
   UI, or the populator investigation). Nothing is deferred unless context limits
   force it.

---

*End of Session 35 summary. Batch Monitoring is migrated, deployed, visually
verified (clean first pass), and drift-clean to the 2-row transitional floor.
Next session: migrate Server Health — the last platform page, and the biggest.*

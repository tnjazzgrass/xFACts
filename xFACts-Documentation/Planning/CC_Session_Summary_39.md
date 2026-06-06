# CC Session Summary 39 — Platform Monitoring Migration

**Date:** 2026-06-06
**Page migrated:** Platform Monitoring (`ControlCenter.Platform`, prefix `plt`)
**Status:** Complete — final drift 0 / 0 / 0 / 2 (css / js / api / route)
**Position in initiative:** Second-to-last page. **Admin is last** (scouted this session — see §8).

---

## 1. Scope

Migrated all four Platform Monitoring files to the four format specs
(CC_PS_Spec, CC_HTML_Spec, CC_CSS_Spec, CC_JS_Spec). Platform Monitoring is an
on-demand snapshot page (no polling schedule, no engine cards) that shows the
environmental impact of xFACts processes plus Control Center API metrics. It is
a tile-only, admin-gated, non-nav page (same access model as Admin).

The four current files were read in full before any build (route, API, CSS, JS),
along with cc-shared.css, cc-shared.js, and both CSS/JS populators.

---

## 2. What shipped, per file

### Route (`PlatformMonitoring.ps1`, 261 lines)
- CBH header; CCShared import shim as first statement of the route scriptblock
  (the transitional convention); `Get-UserAccess` gate; `$ctx` / `$navHtml` /
  `$headerHtml` / `$browserTitle` / `$bannerHtml`.
- Body `cc-section-admin`, `data-cc-page="platform-monitoring"`,
  `data-cc-prefix="plt"`. H1 accent maps to `--color-accent-platform`.
- `cc-header-bar` + verbatim refresh-info block (incl. `cc-live-indicator` +
  "Live" per HTML §2.2.1, even though the page is not live-polling). No engine
  row, no back-link (dead pre-RBAC code removed).
- `$bannerHtml` replaces the old literal connection-error div.
- All `pm-` -> `plt-`; `onclick` -> `data-action-click`; clickable cards use a
  full-cover `<button class="plt-card-hit">`; three overlays contiguous (info
  modal + date modal as `cc-modal-overlay cc-hidden`; detail slideout as
  `cc-slide-overlay` + `cc-dialog cc-dialog-slide`).
- Vendored `/js/chart.min.js` before the single mandatory `/js/cc-shared.js`.
- Two dead class references removed during audit (see §4): `plt-alert` (3 cards),
  `plt-chart-col` (1 column).

### API (`PlatformMonitoring-API.ps1`, 538 lines)
- Surgical transform; logic byte-identical to pre-refactor except one intended
  inline-SQL -> here-string conversion (verified via normalized diff).
- CBH header; single `ROUTE: API ENDPOINTS` banner (no CHANGELOG — forbidden in
  api-route files).
- All 10 GET endpoints gained `Test-ActionEndpoint` as the first statement (was
  absent pre-refactor). Per-endpoint `# ===` dividers and `# GET` comments
  removed; trailing-whitespace lines inside SQL stripped.
- No function definitions, no raw `Invoke-Sqlcmd`; all SQL via
  `Invoke-XFActsQuery`.
- One trailing comment moved to its own leading line during audit (see §4).

### CSS (`platform-monitoring.css`, 1267 lines)
- Full rewrite into LAYOUT + 9 CONTENT sections. All `pm-` -> `plt-`, all ~86
  forbidden selectors flattened to state-on-element classes, property-context
  tokenization (exact-match only — token-less literals kept literal).
- Six canvas `!important` rules kept (no drift code exists for them; load-bearing
  for Chart.js inline-style override).
- Two descendant-flatten traps caught during the build and fixed to flat classes:
  `.pm-card-dual .pm-card-val` -> `.plt-card-dual-val` (+ JS branch), and
  `.pm-mini-gauge.selected .pm-mini-gauge-name` -> `.plt-mini-gauge-name-selected`.
- Info-modal body content classes added (flattened from old `.pm-info-modal-body`
  descendant rules): `plt-info-body/label/label-api/thresholds/threshold-line/
  green/yellow/red`. Info-modal paragraphs use shared `cc-dialog-paragraph` +
  `cc-last` (exact match to old `p` / `p:last-child`).
- Post-walkthrough fixes folded in (see §3): `.plt-card { position: relative }`
  and `.plt-info-icon { position: relative; z-index: 2 }`.
- 14 variant trailing-comment fixes folded in during audit (see §4).

### JS (`platform-monitoring.js`, 1454 lines)
- IIFE `PM = (function(){...})()` unwound to top-level `plt_*` functions
  (~45 functions). Sections: CONSTANTS (`plt_ENGINE_PROCESSES` as `var`,
  `plt_INFO`, `plt_clickActions`) -> STATE -> FUNCTIONS (INITIALIZATION =
  `plt_init` only; named work banners; PAGE LIFECYCLE HOOKS = `plt_onPageResumed`
  only, last).
- Shared-call adoption: `esc` -> `cc_escapeHtml`, `engineFetch` ->
  `cc_engineFetch`, `alert()` -> `cc_showAlert`, `showError`/`clearError` ->
  `cc_renderPageError` (old `connection-error` element gone).
- Every JS-emitted `onclick` -> `data-action-click` + arg attributes, routed
  through `plt_clickActions` via one delegated body listener (`plt_dispatchClick`).
  Added action keys for JS-rendered controls: `plt-sort-process`/`plt-sort-api`
  (`data-action-plt-sort-col`), `plt-toggle-sql` (`data-action-plt-sql-id`);
  mini-gauge select reuses `plt-select-server`.
- Midnight-rollover `setInterval` moved into `plt_init`. Chart.js gauge + trend
  construction moved in from the old inline route script.
- Modals on the static `cc-hidden` toggle pattern with backdrop guard (§11.5.2);
  slideout on the `cc-open` RAF-open + one-shot `transitionend` close (§11.5.3).
- LF line endings, no BOM, ASCII (glyphs as `\u` escapes), single trailing
  newline.

Byte discipline upheld on every file and every redelivery: no BOM, pure ASCII,
PS + CSS CRLF, JS LF, single trailing newline.

---

## 3. Engine-processes decision (corrected mid-session)

**Initial S39 scoping said to delete the engine scaffolding entirely.** That was
reversed after tracing `cc_connectEngineEvents()` in cc-shared.js:

- The function early-returns on a falsy/undefined `<prefix>_ENGINE_PROCESSES`.
- Everything downstream of that guard — visibility-resume (`onPageResumed`), idle
  detection, the connection banner, the global Escape/outside-click handlers — is
  bundled behind it.
- So a card-less page that declares **no** map and does **not** call
  `cc_connectEngineEvents()` loses all of that page-lifecycle chrome.
- The old page declared an empty-but-truthy `ENGINE_PROCESSES = {}` precisely to
  pass the guard and opt into the chrome lifecycle without having cards.

**Confirmed against the spec and guidelines:**
- CC_JS_Spec §7.2 is conditional ("pages *with* engine cards declare..."), never
  mandating omission on card-less pages.
- The JS populator fires `MISSING_ENGINE_PROCESSES_DECLARATION` only when
  `Orchestrator.ProcessRegistry` has a registered process for the route. Platform
  has none, so an empty map draws no drift. Both keeping `{}` and omitting it are
  drift-clean — the spec/populator are neutral.
- `xFACts_Development_Guidelines.md` A-4.1/A-4.2 documents the empty-map pattern
  as a sanctioned exception used by Platform, Administration, and Client Relations.

**Final decision:** keep `var plt_ENGINE_PROCESSES = {}` (CONSTANTS: ENGINE
PROCESSES banner) and call `cc_connectEngineEvents()` in `plt_init`. Keep
`plt_onPageResumed`. Drop the two inert no-op hooks (`onEngineProcessCompleted`,
`onSessionExpired`) — they can never fire on a page with no registered processes.

This preserves exact behavior, is drift-clean, and matches the documented
convention.

---

## 4. Diagnostic / audit arc (in order)

### Post-deploy walkthrough — slideout stacking bug
**Symptom:** every clickable card opened the *API errors* slideout regardless of
which card was clicked. **Root cause:** the new full-cover `plt-card-hit` button
is `position: absolute; inset: 0`, but `.plt-card` had no positioning context, so
all four hit buttons resolved against a shared ancestor and stacked — the last in
DOM order (api-errors) covered everything. This was introduced this pass (the
hit-button pattern is new; the old design used card-level `onclick`). **Fix:**
`position: relative` on `.plt-card` (clips each hit button to its own card) +
`position: relative; z-index: 2` on `.plt-info-icon` (keeps the info `?`
clickable above the `z-index: 1` hit button on the four clickable cards).
**Lesson:** a runtime stacking bug is invisible to every static audit; only the
live walkthrough caught it (same family as S38's totals-color bug).

### Populator audit — 21 non-compliant rows, all resolved to 0/0/0/2
Pre-refactor: 269 / 120 / 12 / 282 non-compliant (css / js / api / route).
Post-refactor first pass: 14 / 0 / 1 / 6.

- **CSS — 14 `MISSING_VARIANT_COMMENT`.** Every `:hover`/`:focus`/`::after`/
  scrollbar-thumb-hover variant rule was missing the trailing inline comment after
  its opening brace. Base classes had leading comments; variants did not. Fixed
  all 14. -> 0.
- **API — 1 `FORBIDDEN_TRAILING_COMMENT`.** `# include end day` trailed a code
  line; moved to its own leading line. -> 0.
- **Route — 4 `HTML_CSS_CLASS_UNRESOLVED` + 2 transitional shim.** The 4
  unresolved were `plt-alert` (x3) and `plt-chart-col` (x1): dead class references
  with no CSS rule, no JS reference, no behavior. Resolved by **removing** them
  from the markup (see §5). The 2 remaining (`MISPLACED_IMPORT` +
  `MISSING_RBAC_CHECK_PAGE`) are the expected end-of-migration transitional shim
  rows, identical to every migrated page; they clear platform-wide at cutover.

Final: **0 / 0 / 0 / 2.** JS clean on the first populator pass.

---

## 5. Empty-class vs. remove-reference decision (and what it exposed)

The 4 `HTML_CSS_CLASS_UNRESOLVED` rows surfaced a question with initiative-wide
implications.

**The immediate call.** `plt-alert` and `plt-chart-col` were referenced in markup
but undefined in CSS. In the original: `alert` was never styled at all (a bare
label), and `.pm-chart-col {}` was a deliberately-empty reserved hook. Neither
carried any styling; neither was referenced by JS. CC_HTML_Spec §13.1 requires
every referenced class to have a matching definition — so the unresolved rows are
genuine violations, satisfiable two ways: define an empty class, or remove the
reference. Both are spec-legal (the empty-class pattern is sanctioned by CC_CSS_Spec
§7.1 for state tokens). **Decision: removed both from markup** — they are dead
labels, not intentional hooks, and the standing no-dead-code rule points to removal.

**No silent skip.** Confirmed (from the drift data itself) that a static class
reference always emits a USAGE row; if it cannot resolve, that row is stamped
`HTML_CSS_CLASS_UNRESOLVED` (loud). Removing the reference produces no row because
there is genuinely no usage — accurate, not a quiet omission. The only genuinely
silent case is dynamically-built references (`'plt-' + key`), which emit no USAGE
row — the known Session 32 dynamic-reference gray area, separate from this.

**The concern this raised (FOLLOW-UP — see §7).** The migration's default reflex
has been "add the empty class to satisfy §13.1." That may have *preserved* dead
hooks across earlier pages that should have been *removed* (`plt-chart-col` is a
proven instance). The catalog can audit its own files for this.

---

## 6. Production incident — DM-PROD-DB XE collection (fully diagnosed + fixed)

The missing DM-PROD-DB tile on Platform Monitoring led to a full investigation of
`Collect-XEEvents.ps1` (the XE collector, `ServerOps.ServerHealth`,
component-versioned, NOT yet refactored — standalone scripts are a later phase).
**Four distinct findings**, diagnosed empirically (three wrong hypotheses were
discarded along the way — the discipline that mattered was confirming against
real runtime/disk state, not reasoning ahead of the data).

### Finding 1 — Stranded incremental cursors (root cause of the missing tile)

The server tiles are built from `impact-summary`'s grouping of
`ServerOps.Activity_XE_xFACts` by `server_name` — a server only tiles if it has XE
activity in the window. DM-PROD-DB (AG primary, server_id 1) had a hard stop at
2026-04-12 (4.2M historical rows, then nothing) while every other server was
current.

**Root cause (confirmed via on-disk file listing):** the collector reads
incrementally via `sys.fn_xe_file_target_read_file('<wildcard>.xel', NULL,
$lastFileName, $lastOffset)`, persisting `last_file_name` / `last_file_offset` per
server/session in `ServerOps.Activity_XE_CollectionState`. The April AG event (and
a 2026-05-16 session recreate) started a new `.xel` file lineage. The collector's
cursor for DM-PROD-DB's sessions became **stranded on a rollover file that has
since aged off disk** — the stored cursor file (tick `...134204…`) is older than
the *oldest* file currently on disk (ticks `...134252…`, all written today).
`fn_xe_file_target_read_file` asked to resume from a missing start-file returns
**zero rows**, so the collector stamped `NO_DATA`, re-saved the same dead cursor,
and looped — silently, for ~50 days. Connection, session, STARTUP_STATE, and
routing were all fine; the connection target is a direct per-server hostname
(`Get-SqlInstanceName`), NOT the AG listener — the early AG-routing hypothesis was
wrong.

**Fix (data, not code):** null the stranded cursor so the collector falls into its
initial-collection branch (`fn_xe_file_target_read_file('<wildcard>', NULL, NULL,
NULL)` → reads all retained files from the beginning):

```sql
UPDATE ServerOps.Activity_XE_CollectionState
SET last_file_name = NULL, last_file_offset = NULL, first_file_offset = 0
WHERE server_name = 'DM-PROD-DB' AND session_name = '<session>';
```

Applied surgically per session (staged, one at a time — `xFACts_Tracking` first,
confirmed clean catch-up + tile returned, then the others). `xFACts_Tracking`
recovered (a ~15-minute catch-up ingesting the retained backlog); the DM-PROD-DB
tile is back on Platform Monitoring.

**Detection was the hard part — the key lesson.** Neither
`last_collection_status = 'NO_DATA'` nor an old `MAX(event_timestamp)` reliably
indicates a stranded cursor: both are the *normal* state for rare-event sessions
(LRQ, Deadlock, BlockedProcess, AGHealth can legitimately sit quiet for
hours/days). The **only unambiguous signal is the cursor's file being older than
the oldest file on disk** (cursor-tick < newest-file-tick, or stored file absent
from the directory). Per-session freshness via target-table `MAX(event_timestamp)`
for server_id 1 showed the real picture and which sessions were genuinely stranded
vs. merely quiet:

| session | latest event (server_id 1) | state |
|---|---|---|
| LRQ | 2026-06-06 09:38 | healthy (quiet, rare events) |
| BlockedProcess | 2026-06-06 06:31 | healthy |
| xFACts (Tracking) | catching up → current | **reset, recovered** |
| Deadlock | 2026-06-05 09:02 | healthy (rare) |
| AGHealth | 2026-06-03 | assess (3 days plausibly normal) |
| SystemHealth | 2026-05-04 | **stranded — reset (large catch-up)** |
| LinkedServerIn | 2026-04-29 | **stranded — reset** |
| LinkedServerOut | 2026-02-19 (107 days) | **stranded — reset** |

So the stranding was a **subset**, not all eight — the uniform `NO_DATA` snapshot
was misleading (it conflated stranded with quiet).

### Finding 2 — ~50-day unrecoverable data gap (consequence of Finding 1)

The April 12 -> ~early-today window in `Activity_XE_xFACts` for DM-PROD-DB is
**permanently lost** — those `.xel` files rolled off disk long ago. The cursor
reset recovers only what is still on disk (from the oldest retained file forward —
roughly this-morning onward for Tracking). Historical loss is accepted;
current/forward collection is restored.

### Finding 3 — Inconsistent collector self-exclusion across session predicates

The `xFACts_Tracking` session predicate is **correct and intact** (verified
post-recreate):
`[client_app_name] LIKE N'xFACts%' AND [client_app_name] <> N'xFACts Collect-XEEvents'`
— captures xFACts workload but excludes the collector itself. The data confirms
it: every `client_app_name` in Tracking since 2026-05-16 is a legitimate xFACts
process, and `xFACts Collect-XEEvents` does NOT appear. **Platform Monitoring's
CPU-impact numbers are trustworthy — not skewed by self-capture.** (An earlier
worry that the May 16 recreate broke Tracking's filter was disproven.)

However, the **Linked Server sessions** (LinkedServerOut confirmed via the Server
Health tile showing 2,066 "unique" queries that were all the collector's own
`INSERT INTO ServerOps.Activity_XE_LinkedServerOut`; LinkedServerIn likely) do
NOT carry the `Collect-XEEvents` self-exclusion. They capture the collector's own
inserts as linked-server events. This is arguably *correct* capture (the collector
genuinely makes LS calls to the xFACts DB) but is undesirable noise on Server
Health. The large counts seen during this session were inflated by the in-progress
stranded-cursor catch-up and will subside; the residual steady-state self-capture
remains.

**Fix (collector-refactor phase):** add the same `<> N'xFACts Collect-XEEvents'`
exclusion to the Linked Server session predicates, and **audit all session
predicates for consistency** (Tracking has the exclusion; LS does not; the others
are unverified). Separately consider whether already-ingested self-capture rows in
the LS tables warrant cleanup.

### Finding 4 — Collector reads an entire session backlog into memory before insert

The collection loop does `$events = Get-SqlData -Query $xeQuery ... -MaxCharLength
2147483647` — a single read that materializes the **entire** result set into memory
before any parsing or inserting begins; the `events_collected` / status MERGE only
runs after the full read+insert completes. Normal incremental runs keep this small,
but during a large catch-up (exactly the stranded-cursor recovery we triggered) it
means a long silent phase (no table rows during the read), high memory pressure,
and risk of a memory/timeout failure on high-volume sessions. Observed live:
`system_health`'s catch-up ran 15+ minutes with no visible table activity — the
expected (if fragile) all-at-once read phase, not a hang.

**Fix (collector-refactor phase):** batch/paginate the read (read N events, insert,
advance cursor, repeat) so catch-ups stream incrementally, commit progress as they
go, are resumable if interrupted, and cannot blow memory. Complements Finding 1's
self-healing (a batched reader recovers from a large backlog gracefully).

### Finding 5 — Query timeouts are silently misclassified as NO_DATA

Observed live on the `system_health` catch-up: the all-at-once read (Finding 4)
of the full retained backlog exceeded the `Get-SqlData` default command timeout
(~5 min) and threw `Execution Timeout Expired`. The collector's loop wraps the
read in `try` and tests `if ($null -eq $events -or @($events).Count -eq 0)` — a
timeout returns null, which is **indistinguishable from a legitimate empty
result**, so the collector logged `No new events found`, stamped `NO_DATA`
(success-with-zero), and moved on. It never stamps `FAILED` on a timeout. Log
evidence:

```
[10:39:06] Session: system_health / Last offset: None (initial collection)
[10:44:08] [ERROR] SQL Query failed on DM-PROD-DB/master: Execution Timeout Expired.
[10:44:08]     No new events found            <- timeout swallowed as NO_DATA
```

This is a distinct silent-failure path that compounds Findings 1 and 4: a read too
big to complete looks identical to a quiet session, swallows the error, and
re-fails every cycle. No `Get-SqlData` call in the collector passes a timeout
parameter (all use the shared default); whether the shared `Get-SqlData` even
accepts a per-call timeout is unverified (its signature is in the
`Initialize-XFActsScript` infrastructure, not this script).

**Immediate workaround ATTEMPTED and ABANDONED (system_health):** tried to seed
the cursor at the current file to bound the read. This does NOT work, for two
compounding reasons: (1) the collector's read branch tests `if ($lastFileName -and
$lastOffset)`, and a NULL offset is falsy, so "current file, offset NULL" (which
`sys.fn_xe_file_target_read_file` supports as read-from-start) falls through to the
full-backlog `else` branch and times out; (2) seeding a non-zero offset to pass
that gate fails with `Msg 25722 - offset is invalid` — the function's
`initial_offset` requires a function-blessed *resume boundary*, NOT any
`file_offset` value the function returns (offsets `1` and a real returned offset
`8050688` were both rejected). There is no cursor value that expresses "current
file from the start" through the collector's current branching. **system_health is
therefore left stranded for now** — it feeds Server Health, NOT Platform Monitoring
(`Activity_XE_xFACts` is fixed and current), so nothing user-facing on the migrated
page is affected. The proper fix is the batched/NULL-based read in the collector
refactor (Finding 4), which makes a current-file read safe regardless of backlog
size. A short-term live option if collection is needed before the refactor:
relocate (don't delete) the older `system_health*.xel` files out of the log
directory so the wildcard matches only the current file, then null the cursor so
the `else` branch reads just that file — but this was judged not worth doing live.

**Refactor item exposed:** the `if ($lastFileName -and $lastOffset)` gate cannot
express "named file, read from start" (NULL offset), because `0`/NULL are falsy.
The branch logic should test for file presence independently of offset so a
current-file-from-start read is expressible.

**Fix (collector-refactor phase):** the `try/catch` must distinguish a timeout/
exception from a genuine empty result and stamp `FAILED` (not fall through to the
empty-result branch). Pair with batched reads (Finding 4) so large catch-ups never
time out in the first place. If feasible, expose a per-call command timeout on the
read (verify the shared `Get-SqlData` signature first).

### Systemic gap exposed (across Findings 1, 3, 4, 5)

Nothing alerted on a single server's feed going dark for ~50 days because the
aggregate kept flowing and `NO_DATA` is indistinguishable from "quiet." The
collector needs (a) **stranded-cursor self-healing** — before each read, if the
stored cursor file is no longer in the on-disk set, auto-reset to initial
collection and alert; and (b) **per-session cadence-aware staleness alerting** —
keyed on each session's *expected* cadence (Tracking should produce events every
few minutes; AGHealth may be quiet for days), NOT on `NO_DATA` or raw
max-timestamp age. See §7 #6. Pairs with the CC-side per-server staleness
indicator (#7).

---

## 7. Follow-ups and next steps

### Spec amendments to draft (audit phase of this initiative; spec first,
populator deferred to the populator-edit session)

1. **CC_JS_Spec §7.2 — make `CONSTANTS: ENGINE PROCESSES` required for every
   page.** Currently conditional. Populator change scoped (small, localized, no
   new drift code): in `Populate-AssetRegistry-JS.ps1` — (a) lift the
   "declaration present?" check out from under the
   `$processRegistryByPageRoute.Count -gt 0` registry gate so it runs for every
   page file with a registered cc_prefix (like `MISSING_PAGE_INIT`); (b) change
   Case 1's condition from `registryEntriesForThisPage.Count -gt 0 -and $null -eq
   $script:CurrentEngineProcessesRow` to just `$null -eq ...Row`; (c) update the
   `MISSING_ENGINE_PROCESSES_DECLARATION` drift_text.

2. **CC_HTML_Spec §13.1 — clarifying note (optional).** Add: "An unresolved
   reference is satisfied either by removing the reference or by adding a matching
   definition. When the referenced class is an intentional but currently-unstyled
   hook, the sanctioned definition form is an empty class (`{ }`) with a purpose
   comment, per §7.1." This documents the empty-class resolution without
   forbidding deletion (keeps the no-dead-code path legal). Deliberately NOT a
   hard mandate — mandating the empty class would make legitimate dead-code
   removal a violation.

### Audit (next steps)

3. **Audit all card-less pages for empty-map conformance.** Confirm every
   card-less page (Administration, Client Relations, any others per the A-4.1/
   A-4.2 exception tables) declares `<prefix>_ENGINE_PROCESSES = {}` (var,
   CONSTANTS: ENGINE PROCESSES banner) AND calls `cc_connectEngineEvents()` — i.e.
   none silently omitted the map and lost idle/visibility/banner chrome.

4. **[NEW] Catalog self-audit for orphaned / empty CSS classes.** The migration's
   "add the empty class" reflex may have preserved dead hooks. The catalog can
   find these: a `CSS_CLASS` DEFINITION row whose body is empty AND that has no
   matching USAGE row anywhere in its component/zone AND that participates in no
   compound selector (the compound exclusion is essential — §7.1 state tokens are
   intentionally empty). Two phases: (a) a diagnostic query across all migrated
   CSS files to size and list the orphaned/empty classes — **verify the exact
   `Populate-AssetRegistry-CSS.ps1` column semantics first** (`component_name`,
   compound-token matchability via `raw_text`, `variant_type`/`variant_qualifier`)
   before trusting any SQL; (b) propose a standing drift code
   (`CSS_CLASS_DEFINED_BUT_UNUSED` / `ORPHANED_CSS_CLASS`) so the resolve phase
   flags definition-without-usage the way it already flags usage-without-definition
   (`HTML_CSS_CLASS_UNRESOLVED`), making this self-policing. Generalizes to
   non-empty dead classes too. Shares compound-detection logic with the deferred
   `STATE_NOT_COMPOUNDED` code (S32 §6.1). **Known limitation:** a class
   referenced *only* via dynamically-built selectors emits no USAGE row, so the
   orphan query would falsely flag it — any orphan sweep must be cross-checked
   against dynamic usage before deletion (human-confirmed, not blind delete).

### Shared-layer note (contingent)

5. **Page-lifecycle chrome is mis-coupled inside `cc_connectEngineEvents()`.** The
   idle/visibility/banner/global-key wiring sits behind the `ENGINE_PROCESSES`
   guard even though it is logically independent of engine cards. Candidate fix:
   split a `cc_initPageChrome()` out so card-less pages get chrome without the
   empty-map trick. **Contingent on follow-up #1** — if we bless empty-map-
   everywhere as the spec requirement, the empty map becomes the intentional
   universal contract and the split is likely moot. Two-horned fork; do not do
   both.

### Production / ops (independent of migration)

6. **[INCIDENT — diagnosed + immediate fix applied] DM-PROD-DB XE stranded cursors.**
   Root cause confirmed (see §6 Finding 1): incremental cursors stranded on
   rolled-off `.xel` files after the April AG event / May 16 recreate. Immediate
   fix (cursor reset) applied per-session this session; `xFACts_Tracking` recovered
   and the tile is back; SystemHealth / LinkedServerIn / LinkedServerOut reset
   (SystemHealth a large catch-up); AGHealth to assess (3-day quiet may be normal).
   **Collector-refactor-phase follow-ups (standalone-scripts phase, NOT done):**
   - **(a) Stranded-cursor self-healing.** Before each read, if the stored
     `last_file_name` is no longer in the session's on-disk file set, auto-reset to
     initial collection and alert. Detection MUST key on cursor-file-vs-on-disk-files
     (the only unambiguous signal) — NOT on `NO_DATA` and NOT on max-timestamp age
     (both normal for rare-event sessions).
   - **(b) Per-session cadence-aware staleness alerting.** Alert when a session's
     data stops relative to its *expected* cadence (Tracking: minutes; AGHealth:
     days). Catches strandings AND other failure modes (stopped session, broken
     recreate, connection failure). The ~50-day silent gap is the failure this
     prevents.
   - **(c) Linked Server session self-exclusion (Finding 3).** Add
     `<> N'xFACts Collect-XEEvents'` to the LS session predicates (Tracking already
     has it; LS does not). Audit ALL session predicates for consistency. Consider
     cleanup of already-ingested LS self-capture rows.
   - **(d) Batched/paginated reads (Finding 4).** Replace the single all-at-once
     `Get-SqlData` read (materializes entire backlog in memory before inserting)
     with read-N / insert / advance-cursor batching, so catch-ups stream
     incrementally, commit progress, are resumable, and cannot blow memory on
     high-volume sessions. Complements (a).
   - **(e) Run cadence vs. file rollover.** Confirm the collector runs frequently
     enough to stay ahead of `.xel` rollover (Tracking rolls ~5 files/morning at
     ~50MB each on DM-PROD-DB) so a cursor cannot fall behind the retention window
     and re-strand.
   - **(f) Timeout handling (Finding 5).** The read's `try/catch` must stamp
     `FAILED` on a timeout/exception rather than letting a null return fall through
     to the `NO_DATA` (empty-result) branch — a too-big read currently masquerades
     as a quiet session and re-fails silently every cycle. Pairs with batched reads
     (d). Verify whether the shared `Get-SqlData` accepts a per-call command
     timeout before relying on one.

7. **[ENHANCEMENT] Per-server collection-staleness indicator on Platform
   Monitoring.** A server whose collection has gone stale should show as a dimmed
   "stale / no recent data" tile rather than silently vanishing — the missing tile
   was the *only* visible symptom of the ~50-day outage, and it surfaced only by
   chance. Turns "silently absent" into "visibly wrong." Uses the same per-session
   freshness logic as #6(b). Ties into the snapshot-table retention backlog.

### Version bumps

8. **System_Metadata version bumps** (component-level, append-only, one per
   component per session via Admin UI) for the four ControlCenter.Platform
   components touched.

### CSS literal note (carry-forward, unchanged)

9. Platform carries token-less page-local literals that read clean today only
   because of the multi-line line-key gap in the CSS populator
   (`DRIFT_HEX_LITERAL`/`DRIFT_PX_LITERAL` key on `$fname|$line|$ctype` and only
   fire when a literal shares a line with a selector-opening row; multi-line rules
   put literals on their own declaration lines). These should resurface when the
   populator is corrected to fire on both single- and multi-line rules.

---

## 8. Admin scout (next page — preliminary, re-read fresh next session)

Admin (`ControlCenter.Admin`, prefix `adm`) is the last page and the meta-page
managing the registry/version machinery the initiative itself uses. Scout-level
findings only (structural pass; full read required next session).

**Sizes:** Admin.ps1 388 / Admin-API.ps1 **1579** / admin.js 1337 / admin.css 1229
lines. The heaviest page of the initiative.

**admin.css — the dominant lift.** ~521 selectors across ~10 functional-area
prefixes (`meta-` 101, `gc-` 91, `doc-` 62, `sched-` 54, `tl-` 41, `svc-` 31,
`detail-` 29, `af-` 27, `log-` 17, `cat-` 14), **none of which is `adm-`**. Unlike
Platform's clean `pm-` -> `plt-` rename, every selector needs reprefixing from a
dozen ad-hoc families into `adm-` — no single find/replace. Plus **103 `#id`
selectors** to convert to classes (a structural pattern no migrated page has had
at this scale — likely the biggest single source of cross-file churn, rippling
into route markup + JS `getElementById`), **29 descendant selectors** to flatten,
**11 `@keyframes`** (forbidden — move to cc-shared or convert), **1 `!important`**.

**Admin-API.ps1 — 27 endpoints (16 GET + 11 POST), 1579 lines.** Six functional
areas: process control (status/history/timeline/toggle/drain/service-control),
metadata management (tree/history/objects/insert/add-component — the
System_Metadata machinery), GlobalConfig, schedule (incl. browse-scripts),
doc-pipeline, alert-failure. **Only 12 `Test-ActionEndpoint` guards against 27
endpoints** — ~15 to add. All SQL already via `Invoke-XFActsQuery` (52 calls,
zero raw `Invoke-Sqlcmd`). The mutating POST endpoints carry the real RBAC weight.
(In-route helper-function check deferred — the open
`FORBIDDEN_FUNCTION_IN_API_ROUTE` coverage-gap investigation means a naive grep
isn't trustworthy.)

**admin.js — 1337 lines, structurally unique.** NOT wrapped in the page IIFE the
way other pages were — the hooks (`onEngineProcessCompleted`, `onEngineEventRaw`,
`onPageResumed`, `onSessionExpired`) and `ENGINE_PROCESSES` are already at
top-level, but an `Admin.*` object exists (referenced by the hooks). The module
shape needs investigation next session. Uses **`onEngineEventRaw` as its primary
event path** (the only page to — drives the Process Timeline from every WebSocket
event; `onEngineProcessCompleted` body literally notes it is unused). Empty
`ENGINE_PROCESSES = {}` (keep, per §3). **4 `setInterval` timers** incl. the
documented 5s timeline ticker. **38 `onclick` + 1 `onchange` + 1 `oninput`** to
dispatch. **7 `let`** to convert. Dense multi-statement one-liners to unpack.

**Admin.ps1 route — 388 lines.** 52 `onclick` to convert, retained `.live-indicator`
(line 58) per the documented exception, no engine cards, no dead back-link, no
inline `<script>` blocks.

**Sanctioned exceptions to PRESERVE (do NOT "fix") — verify against A-4.1/A-4.2
first:** the 5s self-managed timeline `setInterval`; the `.live-indicator`
(pulsing dot + "Live"); the empty `ENGINE_PROCESSES`; `onEngineEventRaw`. Admin is
*the* exception-heavy page — re-reading the exceptions table is next session's
first move.

**Decisions to tee up (do not resolve now):** (1) do the 103 IDs become
`adm-`-prefixed classes, and the cross-file ripple into route markup + JS
`getElementById`? — the biggest churn/risk; (2) `.live-indicator` keep-as-is vs
`cc-live-indicator`; (3) the admin.js module shape — what is `Admin.*` and how
does it unwind given the hooks are already global; (4) preserving the
`onEngineEventRaw` timeline wiring exactly through the dispatch migration.

**Effort gauge:** ~1.5–2x a normal page, front-loaded into the CSS (reprefix +
ID-to-class conversion) and the 27-endpoint API. This is why Admin was saved for
last.

---

## 9. Cross-references

- `CC_Session_Summary_38.md` — predecessor; Client Portal migration + Platform
  Monitoring scope.
- `CC_PS_Spec.md` — route/api-route canonical forms, SQL here-strings.
- `CC_HTML_Spec.md` — body shell, refresh-info, overlays §5.4, §13.1 cross-spec
  resolution.
- `CC_CSS_Spec.md` — state-on-element, §7.1 compound/state-token (empty class
  pattern), per-class + per-variant comments.
- `CC_JS_Spec.md` — banner order, INITIALIZATION/HOOKS, §7.2 ENGINE_PROCESSES,
  §11.5 overlay handlers, §15 forbidden patterns.
- `xFACts_Development_Guidelines.md` — A-4.1/A-4.2 refresh + engine-indicator
  exception tables.

---

## 10. End-of-migration cutover (after Admin)

Unchanged, pending:
- Helpers-vs-CCShared shared-function-body diff before flipping
  `Start-ControlCenter` to load CCShared (quick 2-file diff).
- Cutover: flip startup load, strip per-route import shims (clears all
  transitional `MISPLACED_IMPORT` + `MISSING_RBAC_CHECK_PAGE` rows platform-wide),
  retire `xFACts-Helpers.psm1` and `engine-events.js`/`.css`.

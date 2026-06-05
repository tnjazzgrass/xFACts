# CC Session Summary 36

## Server Health page migration (prefix `srv`)

---

## 1. Scope

Migrated the **Server Health** page -- the **last live platform page** and the
single most heavily used page by the team -- to the four CC file-format specs.
Four source files refactored: page route (`ServerHealth.ps1`), API route
(`ServerHealth-API.ps1`), CSS (`server-health.css`), JS (`server-health.js`).
This is the only CC page spanning two modules, with the largest source footprint
of any page to date (~4,950 source lines pre-refactor across the four files).

Overriding constraint for this page: **it must continue to operate exactly as
before**, even at the expense of accepting some short-term drift. Behavior
preservation outranked drift reduction throughout.

Final state: all four files deployed, visually verified, and functionally
correct. Residual drift is a small, fully-categorized set -- the transitional
import-shim floor, known populator gaps, and one **deliberately retained** drift
cluster kept as a specimen (see section 5).

Component: `ServerOps.ServerHealth`, cc_prefix `srv`, route `/server-health`,
body section `cc-section-platform`. Engine cards (in cc_sort_order):
Collect-DMVMetrics -> `dmv`/DMV, Collect-XEEvents -> `xe`/XE,
Collect-ServerHealth -> `disk`/DISK, Send-DiskHealthSummary ->
`disksummary`/SUMMARY.

---

## 2. Files delivered

- **`ServerHealth.ps1`** (476 lines) -- single `$html` here-string; transitional
  CCShared import shim as first statement in the route ScriptBlock; approved
  HTML-spec header-bar amendment applied (`cc-header-center` gated by
  `cc-has-center`, carrying the server-tabs strip). 3 residual rows (transitional
  + header-center populator gap).
- **`ServerHealth-API.ps1`** (1441 lines) -- 24 endpoints, each with
  `Test-ActionEndpoint` as the first statement. Listener-DB reads via
  `Invoke-XFActsQuery`; per-server DMV/master reads via direct `Invoke-Sqlcmd`
  (`-TrustServerCertificate -ApplicationName 'xFACts Control Center'`); audit
  insert via `Invoke-XFActsNonQuery`. Zero raw ADO, zero `Write-Host`. 4 residual
  rows (all `MISSING_PARAMETER_DECLARATION` false positives).
- **`server-health.css`** (1747 lines) -- all `srv-` prefixed; every selector
  flattened to state-on-element classes (zero descendant/child/sibling
  combinators, zero `:not`); all pseudo variants carry trailing comments; all
  compound state tokens carry empty standalone defs. CRLF / ASCII / no BOM /
  single trailing newline. 6 residual rows (deliberate literal specimen).
- **`server-health.js`** (2259 lines) -- bootloader contract (`srv_init` entry,
  `var srv_ENGINE_PROCESSES`, all functions/state `srv_`-prefixed); all inline
  `onclick` -> `data-action-click="srv-*"` + `data-action-srv-*` routed through
  `srv_clickActions` via one delegated body listener; modals via `cc-hidden`
  toggle, slideouts via the §11.5.3 static slide-overlay pattern. LF / ASCII /
  no BOM / single trailing newline. 0 residual rows.

---

## 3. Deploy / fix arc (in order)

All found via deploy-and-eyeball plus two populator passes; all fixed and
redelivered.

1. **Three modal overlays visible on page load.** `srv-modal-zombie/-trend/
   -xe-time` were missing `cc-hidden` in the route markup. `.cc-modal-overlay`
   is `display: flex` by default, hidden only with `cc-hidden`. Added to all
   three.

2. **"Page boot failed."** `srv_init` called `srv_loadThresholds()`, which had
   been dropped during the port. Restored it (maps `/api/config/thresholds`
   GlobalConfig onto `srv_thresholds`). **Lesson, now a standard verification
   step:** full call-graph reconciliation -- every `srv_` function CALLED must be
   DEFINED -- not just dispatch-handler and class-resolution checks. Final graph:
   111 called / 111 defined.

3. **Zombie-kill audit INSERT threw `@errorMessage not supplied`.** `$null` in a
   `-Parameters @{}` hashtable makes `AddWithValue` drop the parameter entirely,
   so SQL sees the `@errorMessage` placeholder with no matching parameter. On a
   *successful* Teams post (the normal case) `$errorMessage` was `$null`. Fixed
   to `[DBNull]::Value`. The kill itself had run (alert fired), which is why the
   error surfaced only in the modal.

4. **Second, latent instance of the same bug.** The XE blocking-victims endpoint
   passed `$blockerSpidParam = ... else { $null }` into a `-Parameters` hashtable
   for a `(@blockerSpidParam IS NULL OR ...)` query. The original raw-ADO code
   used `[DBNull]::Value` here; the wrapper refactor lost it. Fixed. Audited all
   13 `-Parameters` blocks: only these two carried nullable values; both now
   DBNull-guarded. **Lesson, now standard:** any raw-ADO -> CCShared-wrapper
   refactor must preserve `[DBNull]::Value` for every nullable SQL parameter --
   the wrapper does no `$null` -> DBNull coercion by design.

---

## 4. Drift cleared this session (the spec-says-so oversights)

Pre-refactor -> post-refactor non-compliant rows:

| file | TotalRows | Compliant | NonCompliant (was -> now) |
|---|---|---|---|
| server-health.css | 347 -> 766 | 24 -> 760 | 323 -> **6** |
| server-health.js | 890 -> 835 | 485 -> 835 | 405 -> **0** |
| ServerHealth-API.ps1 | 128 -> 186 | 99 -> 182 | 29 -> **4** |
| ServerHealth.ps1 | 556 -> 557 | 164 -> 554 | 392 -> **3** |

(CSS TotalRows rises because the refactor splits compound/state constructs into
the standalone-token + compound form the spec requires.)

Fixes applied (CSS, with paired JS edits where flattening required markup
changes):

- **17 `UNDEFINED_CLASS_USAGE`** -- compound state tokens (`srv-badge-*`,
  `srv-role-*`, `srv-value-*`, `srv-lead-blocker`, `srv-status-sleeping`,
  `srv-long-running`/`srv-very-long-running`, `srv-duration-*`, `srv-wait-*`,
  `srv-section-blocked`) lacked standalone single-class defs. Added empty
  `.srv-x { }` with purpose comments per §7.1. This same fix cleared both **JS
  `JS_CSS_CLASS_UNRESOLVED`** rows (shared resolution).
- **13 `MISSING_VARIANT_COMMENT`** -- trailing inline comments added to every
  pseudo variant.
- **1 `FORBIDDEN_NOT_PSEUDO`** -- `.srv-ag-summary-row:not(:last-child)` inverted
  to base-divider + `:last-child` removal (matches the existing `srv-info-row`
  pattern).
- **12 `FORBIDDEN_DESCENDANT`** -- ALL flattened, each with a lockstep JS markup
  edit so no styling is orphaned (the Session 33 lesson):
  - Transactions table: `srv-trans-table th/td/tr:hover td` ->
    `srv-trans-th`/`srv-trans-td`/`srv-trans-row` (emitted on every cell/row;
    row hover moved onto the row).
  - `srv-mini-gauge-wrap canvas` -> `srv-mini-gauge-canvas`;
    `srv-speedometer svg` -> `srv-speedometer-svg` (emitted in the JS builders).
  - Inline highlight spans (`srv-blocker-details span`, `srv-request-details
    span`, `srv-victim-details span`, `srv-blocked-by span`) ->
    `srv-detail-value`/`srv-victim-value`/`srv-blocked-by-value`, applied at all
    span sites scoped per container. Included 7 system-health detail spans built
    in a `details.push` array (assembled into the div later) that a naive
    block-scoped pass missed -- caught by before/after span counts.
  - Ancestor-state -> child state class: `srv-mini-gauge-name-selected` (toggled
    at render + both selection sites), `srv-blocker-section-title-blocked`, and
    the metric tooltip `srv-tooltip-visible` (delegated `mouseover`/`mouseout`
    handlers per §7.2 -- "the state goes on the element that changes").
- **Removed dead `srv-query-text-content`** -- carried from the original, never
  referenced even pre-refactor (no-dead-code rule).

Post-flatten verification PASSED: byte-clean both files; zero descendant
combinators remain; 111/111 call graph; all dispatch handlers defined; every
`srv-` class referenced by JS or route resolves in CSS; dynamic class families
complete; no orphans.

**Deliberately NOT changed: 47 compound state rules without trailing comments.**
The spec (§7.1) documents the trailing comment on compounds, but the populator
does not enforce it (Session 32 noted it as guidance-only); these produced ZERO
drift rows. Adding 47 comments mid-cleanup is scope-creep into unenforced
guidance; they will surface uniformly across all pages when/if the populator
enforces it.

---

## 5. Residual drift (the finish-line state)

**server-health.css -- 6 rows, deliberately retained as a populator-gap
specimen:**
- `#ff4444` x4 (`DRIFT_HEX_LITERAL`), `#6ed7c5` x1 (`DRIFT_HEX_LITERAL`),
  `48px` x1 (`DRIFT_PX_LITERAL`).
- These are **token-less page-local literals** -- there is no cc-shared token for
  any of these values. Under the project's standing rule (tokenize only on exact
  *purpose* match, never round, never coincidental value match), they correctly
  remain literals. Verified: **zero** literals in this file are a true
  purpose-match to an existing token; every literal is either token-less or a
  value-collision with a differently-purposed token (e.g. `background: #333`
  collides with `--color-border-divider` #333, but that token is a border color,
  not a background -- converting it would inject false semantic coupling).
- They drift only because they sit in **single-line** rules; see the populator
  line-key bug in section 6. We are keeping this drift on purpose -- it is the
  one visible specimen of the literal-inventory gap, and conforming this page
  would erase the signal we want to carry into the populator-design session.

**ServerHealth-API.ps1 -- 4 rows, populator false positives:**
- `MISSING_PARAMETER_DECLARATION` on four `Invoke-Sqlcmd` calls. The populator
  flags T-SQL local `DECLARE @x` statements inside the query body as un-supplied
  Pode `@param` placeholders. Not a code defect (same false positive noted on
  prior pages; cannot be cleared without either rewriting correct SQL or fixing
  the populator).

**ServerHealth.ps1 -- 3 rows, all expected/known:**
- `MISPLACED_IMPORT` + `MISSING_RBAC_CHECK_PAGE` -- the transitional CCShared
  import-shim floor, identical to every migrated page. Clears at end-of-migration
  when the shim is removed platform-wide.
- `MISSING_HEADER_BAR` -- the known `cc-header-center` populator gap (the
  header-bar structure check does not yet accept the approved center-column
  child).

---

## 6. Populator backlog (developed this session)

The literal discussion this session surfaced a real, multi-part gap. Recorded
here for a dedicated design session (target: after the remaining cc-zone pages
are done and the shim is removed). Headline items:

### 6.1 -- `DRIFT_HEX/PX_LITERAL` line-key bug
The Pass-3 literal check keys on the **literal's declaration line**
(`$hex.Line`) but looks up rows by the **rule's selector line** (`line_start`).
For single-line rules these coincide and the drift fires; for multi-line rules
they do not and **no row of any kind is emitted for the literal.** Consequence:
prior pages kept token-less literals in multi-line rules and show zero drift,
while Server Health drifts on the same kind of value because some of its literals
sit in single-line rules. Same handling, different rule formatting, different
catalog outcome.

### 6.2 -- Literal check should be purpose-aware, not value-match
Proven concrete by this file: value-match is the wrong test. A literal is a true
violation only when its value matches a token **and the property is in that
token's purpose category** (a `background: #333` is not drift just because a
border-color token is also #333). Token naming is purpose-based, not
appearance-based (§10.1), so the check must be too.

### 6.3 -- Tier model for literals (the inventory the project actually wants)
- **Tier 1 (drift):** value + purpose match to an existing token ("you had a
  token, use it"). `DRIFT_HEX/PX_LITERAL` reserved for this only.
- **Tier 2 (non-drift inventory):** every token-less literal gets a catalog row
  -- value, property, owning class, section, page, scope -- so the full set of
  page-local colors/sizes is queryable. This is the mechanism behind the
  chrome-promotion and cross-page-standardization goals ("critical red must be
  the same red on every page"). **Open fork (deferred to the design session,
  ~4 sessions out):** a distinct `CSS_LITERAL` row per literal occurrence
  (cleaner `GROUP BY value`) vs. a `literal_values` annotation column on the
  existing class/variant row (fewer rows, list-parse to query). Current lean:
  the per-literal row.
- **Tier 3 (queries, no new rows):** chrome-promotion candidates ("x exists in
  SHARED but 3 pages also declare it LOCAL") and "same role, different value
  across pages" are queries over existing/Tier-2 rows, not new drift codes.
  Depend on the naming-convention enforcement that the standardization project
  itself provides.

### 6.4 -- HTML populator: `cc-header-center` (carry-over)
Teach the header-bar structure check to accept the approved optional
`cc-header-center` child gated by `cc-has-center`, and enforce the pairing.
Until done, every page using the center column fires one expected
`MISSING_HEADER_BAR`/`MALFORMED_HEADER_BAR_STRUCTURE`.

---

## 7. Lessons recorded

- **Full call-graph reconciliation is now standard** -- every called `srv_`
  function must be defined, not just dispatch handlers and resolvable classes.
- **DBNull preservation in ADO -> wrapper refactors** -- `$null` in a
  `-Parameters` hashtable silently drops the parameter; nullable SQL params must
  pass `[DBNull]::Value`. Audit every `-Parameters` block.
- **Flattening orphans styling** unless the new class is emitted on the element
  the JS/route actually renders (Session 33 lesson, re-confirmed across 12
  flattens here; before/after span counts caught the system-health miss).
- **Literals: tokenize only on true purpose match.** Never round to the nearest
  tier; never substitute on coincidental value match. This page has zero true
  purpose-matches, so zero literal conversions were correct.
- **Drift philosophy for the refactor phase:** 50 categorized rows on a
  refactored file beats 500+ on an unrefactored one. Fix spec-says-so oversights
  on the spot; leave drift that reflects real populator/spec work as a signal.
  The catalog becomes fully queryable for chrome analysis only once all cc-zone
  pages are done, the shared file is flipped in `Start-ControlCenter.ps1`, and
  the shims are removed -- at which point everything still drifting is
  legitimate.

---

## 8. On the horizon

**Critical path to "catalog is queryable":** finish the remaining cc-zone page
migrations, then flip the shared file in `Start-ControlCenter.ps1` and strip the
route shims. Remaining pages: **Admin, Platform Monitoring, BDL Import, Client
Portal.** Getting through these as quickly as possible is the priority -- it is
the gate that turns all remaining drift into "legitimate, let's discuss."

Carry-forward (unchanged):
- `RBAC_ActionRegistry` rows for the DM Operations launch/abort endpoints; the
  Server Health kill-zombies endpoint is admin-gated server-side via the API but
  has no `RBAC_ActionRegistry` row yet.
- JS populator performance investigation (~4:51 baseline, JS-populator-gated).
- Admin pipeline UI.
- DBCC disk-alert suppression during CHECKDB.
- Helper-module consolidation (`xFACts-Helpers.psm1` deletion) -- blocked until
  all CC pages refactored.
- Literal-inventory / chrome-consolidation design session (~4 sessions out;
  section 6 is its agenda).
- B2B module (`B2B_Roadmap.md` authoritative; investigation-first).

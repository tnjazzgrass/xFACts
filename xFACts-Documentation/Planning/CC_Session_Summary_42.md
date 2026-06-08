# CC Session Summary 42

## Headline

**The CC File Format Initiative reached its terminal milestone.** Admin -- the
last and heaviest CC page -- is at zero workable drift, and the legacy shared
fileset (`xFACts-Helpers.psm1`, `engine-events.css`, `engine-events.js`) has
been retired and superseded by the unified shared fileset
(`xFACts-CCShared.psm1`, `cc-shared.css`, `cc-shared.js`), now fully implemented
and running in production. Every CC page except Home (the never-converted
oddball) is on the unified shared architecture, and the entire CC zone reports
zero drift apart from a small, fully-catalogued punch-list.

Two distinct pieces of work landed this session, on top of the Admin conversion
that completed across Sessions 40-42:

1. **CCShared site-wide cutover** -- `Start-ControlCenter.ps1` flipped to load
   CCShared; per-route import shims removed; Helpers + engine-events deprecated.
2. **Keyframes promotion** -- Admin's 9 page-local `@keyframes` moved into shell
   FOUNDATION, clearing the last mechanical drift bucket on `admin.css`.

---

## 1. Admin page -- COMPLETE (0 workable drift)

Final drift on the four Admin files:

| File | Rows | Status |
|---|---|---|
| Admin-API.ps1 | 0 | clean |
| admin.js | 0 | clean |
| Admin.ps1 | 0 | clean (import shim removed at cutover) |
| admin.css | 9 | doc-toggle/`<details>` only -- the `cc-toggle-*` chrome item |

Work that got Admin there across the triage rounds:

- **CSS standalone class definitions** -- 70 inline empty state-token definitions
  in A&I form (`/* purpose */` then `.adm-token { }` placed immediately before
  each token's first compound), clearing `UNDEFINED_CLASS_USAGE` plus the
  cascading `JS_CSS_CLASS_UNRESOLVED` / `HTML_CSS_CLASS_UNRESOLVED` rows (the
  resolver matches JS/HTML CSS_CLASS USAGE against same-component CSS DEFINITION
  rows, so one CSS fix cleared three files).
- **JS mechanical** -- `var` to `const` (15) in CONSTANTS sections;
  `adm_ENGINE_PROCESSES` moved to its own `CONSTANTS: ENGINE PROCESSES` banner
  (kept `var` per Sec. 7.2.1 carve-out); 4 dispatchers moved to a new
  `FUNCTIONS: EVENT DISPATCH` section and `adm_safetyRefresh` to TIMELINE DATA
  (INITIALIZATION now holds only `adm_init`); `sb.onscroll = ...` per-render
  property-assign replaced with a one-time `addEventListener('scroll',
  adm_onSidebarScroll)` bound at init; 4 missing constant comments added.
- **Underscore IDs** -- 4 doc-status IDs hyphenated in the route
  (`adm-doc-status-generate-ddl` etc.); JS step keys stay underscored as the API
  payload contract; new helper `adm_docStepIdSuffix(stepKey)` =
  `stepKey.replace(/_/g,'-')` bridges the two at the 3 DOM-id build sites.
- **Pseudo-element comments/order** -- `.adm-screw::after`,
  `.adm-switch-handle::after`, `.adm-meta-desc-area::placeholder` converted from
  trailing to preceding purpose comments; `::placeholder` reordered before
  `:focus` (base, then pseudo-element, then variant per Sec. 7.1).
- **Trailing comments + page-shell whitespace** -- 4 `FORBIDDEN_TRAILING_COMMENT`
  in Admin-API.ps1 moved to lead their lines; one blank line inserted between
  `<title>` / page `<link>` / shared `<link>` in `<head>`.
- **`cc-default` removal** -- dropped from the docpipeline and alertfailures
  slide-ups. `cc-default` is NOT a defined chrome class: default slide-up width
  is the ABSENCE of a width modifier (base `.cc-dialog-slideup` already sets
  580px; `cc-narrow`/`cc-wide`/`cc-xwide` override it). Height tier kept.
- **ACTION_ON_NON_INTERACTIVE_ELEMENT (12)** -- 7 platform cards + breaker
  housing + 4 doc pills converted from `<div>`/`<span>` to `<button>`, matching
  A&I's `.aai-tool-card` precedent. CSS button UA resets added to `.adm-card`,
  `.adm-breaker-housing`, `.adm-doc-pill` (`font-family`/`font-size`/`color:
  inherit`, `text-decoration: none`, fuller neutralize on the breaker). All
  three parents are `display:flex`, so the `<button>`'s default `inline-block`
  is overridden to flex-item behavior -- appearance preserved. Overlay outer
  `<div>`s keep their `data-action-click` (the spec-allowed exception). Side
  benefit: cards/breaker/pills are now keyboard-focusable and Enter/Space-
  activatable.

### MALFORMED_*_STRUCTURE scare (resolved -- a lost-edits artifact)

Mid-session, four overlay constructs (metadata, globalconfig, schedule slide-ups
+ log modal) showed `MALFORMED_SLIDEUP_STRUCTURE`/`MALFORMED_MODAL_STRUCTURE`.
Investigation traced this to the prior session's Admin edits having been lost
(deferred-then-dropped), not a markup defect. The deployed HTML populator's
`Test-OverlayConstructStructure` IS subheader-aware (accepts the optional
`cc-dialog-subheader` between header and body) -- the Project Knowledge copy of
`Populate-AssetRegistry-HTML.ps1` was STALE and showed an older 2-or-3-child
check with no subheader slot. A&I's clean catalog slide-up (which uses
`cc-dialog-subheader`) was the proof the deployed validator accepts it. Once
Dirk re-applied the lost Admin edits, the four rows cleared. Lesson reinforced
below.

---

## 2. CCShared site-wide cutover -- DONE

The end-goal of the whole initiative (flagged as blocked since S36): retire the
legacy shared content now that all conversion-relevant pages are migrated.

- **`Start-ControlCenter.ps1`** now loads `xFACts-CCShared.psm1` in place of
  `xFACts-Helpers.psm1`, using the identical Test-Path/Import-Module/Write-Host/
  throw block, in the same position (inside `Start-PodeServer`, after session
  middleware, before the auth scheme and the route-load loop). This is the
  proven pattern -- a module imported there is visible to all Pode route/handler
  runspaces (the comment on the old Helpers block said so explicitly, and the
  whole app already relied on it). Four header/comment references updated to
  CCShared.
- **Per-route import shims** removed by Dirk across every route file.
- **Deprecation** -- `xFACts-Helpers.psm1`, `engine-events.css`,
  `engine-events.js` deactivated in Object_Registry and moved out of the root
  folders into a deprecated folder. CC now runs exclusively on the new shared
  architecture.

### Why the swap was safe (export-surface diff)

CCShared is a functional SUPERSET of Helpers. Helpers exported 37 functions;
CCShared exports 40. Every Helpers export is present in CCShared EXCEPT two,
which were RENAMED (approved-verb cleanup), not dropped:

- `Build-BDLXml`   becomes `ConvertTo-BDLXml`
- `Build-ARLogXml` becomes `ConvertTo-ARLogXml`

CCShared does NOT alias the old `Build-*` names. The only Helpers function
`Start-ControlCenter` itself calls is `Invoke-XFActsQuery` (auth scriptblock,
request-logging endware, the two inline engine routes) -- exported by CCShared
unchanged, so boot infrastructure was unaffected. The only retire risk was any
route still calling the old `Build-*` names (the BDL Import route is the only
plausible consumer); Dirk's route sweep covered this.

### Result

The transitional drift pair (`MISPLACED_IMPORT` + `MISSING_RBAC_CHECK_PAGE`,
2 rows per migrated page from the import shim) cleared PLATFORM-WIDE -- not just
on Admin. `cc-shared.css` (0), `cc-shared.js` (0), `xFACts-CCShared.psm1` (0)
all clean. Zero regressions from the cutover.

---

## 3. Keyframes promotion -- DONE

Admin's 9 page-local `@keyframes` (`adm-breaker-flash`, `adm-spark-fly`,
`adm-pulse-red`, `adm-pulse-yellow`, `adm-badge-pulse-yellow/blue/red`,
`adm-pip-pulse-red/yellow`) were the last `FORBIDDEN_KEYFRAMES_LOCATION` rows.

- **Moved verbatim** into `cc-shared.css` FOUNDATION (after `fadeIn`), keeping
  their `adm-` names. CC_CSS_Spec Sec. 11 requires `@keyframes` to live ONLY in
  shell FOUNDATION, but keyframe NAMES are not prefix-governed -- the shell
  already hosts unprefixed names (`pulse`, `spin`, `page-refresh-spin`,
  `fadeIn`) alongside `ccModalFadeIn`, all passing clean. Names are a global
  animation namespace, not class tokens; `SHELL_SECTION_INVALID_PREFIX` governs
  the section banner's `Prefix:` line, not identifiers. There is NO
  keyframe-reference resolver -- page-side `animation: <name>` references are
  explicitly legal (Sec. 11) and nothing flags an "undefined keyframe."
- **`admin.css` `animation:` references untouched** -- they resolve globally
  against the shell copies. admin.css only lost the 9 definition blocks.
- **`Page: Admin.` notation** appended to each keyframe's single-line purpose
  comment (e.g. `/* Pulses the breaker plate glow ... Page: Admin. */`). This
  satisfies Sec. 11's single-line purpose-comment requirement (the check is
  single-line shape, not sentence count) AND seeds a convention: page-specific
  keyframes that must live in the shared shell are tagged with their owning page
  to deter cross-page reuse. The FOUNDATION banner description was updated to
  document this convention.
- Result: all 9 `FORBIDDEN_KEYFRAMES_LOCATION` cleared; `admin.css` 18 to 9.

### Naming decision (recorded)

Chose Option A (relocate keeping `adm-` names) over Option B (rename to `cc-`).
Spec-legal, lowest-risk (no admin.css reference edits), and the animations ARE
Admin-specific (a circuit-breaker flash / spark-fly is not reusable platform
chrome) -- renaming to `cc-` would falsely imply shared utility. The `Page:` tag
marks ownership without forcing a rename.

---

## 4. CC zone -- final drift state

Every CC file is at 0 EXCEPT:

- **admin.css -- 9:** doc-toggle/`<details>` combinator rows
  (`FORBIDDEN_DESCENDANT`/`ADJACENT_SIBLING`/`GENERAL_SIBLING`/
  `ATTRIBUTE_SELECTOR` + paired `MISSING_PURPOSE_COMMENT`). Native-state-driven
  styling (`input:checked`, `[open]`) that flat single-class CSS cannot express.
  Awaits the `cc-toggle-*` chrome construct.
- **Home.ps1 -- 18+:** the never-converted oddball. Inline `<style>`, hardcoded
  title, no chrome substitutions, no `cc-section`/`data-cc-*`, unresolved local
  classes, malformed file header, `# ---` sub-section markers, trailing
  whitespace. A full format-conversion job, not a drift-cleanup pass. Confirmed
  the cutover does NOT impact Home -- its four shared-function calls
  (`Get-UserAccess`, `Get-UserContext`, `Invoke-XFActsQuery`,
  `Get-HomePageSections`) are all exported by CCShared unchanged.
- **server-health.css -- 6 / ServerHealth.ps1 -- 1 / ServerHealth-API.ps1 -- 4:**
  the deferred-for-chrome ServerHealth fixes. CSS: 5 `DRIFT_HEX_LITERAL`
  (`#ff4444`, `#6ed7c5` where tokens exist) + 1 `DRIFT_PX_LITERAL` (`48px`).
  Route: 1 `MISSING_HEADER_BAR`. API: 4 `MISSING_PARAMETER_DECLARATION` on
  `Invoke-Sqlcmd` here-strings using `@param` placeholders without `-Parameters`
  (mild injection-surface dimension -- the `$([int]$x)` casts type-guard, but
  worth proper parameterization).
- **DmOperations.ps1 -- 3 / IndexMaintenance.ps1 -- 5:**
  `ENGINE_CARD_ORDER_MISMATCH` + `ENGINE_SLUG_REGISTRY_MISMATCH`. KNOWN/BENIGN --
  these engine processes are registered in Orchestrator but `run_mode = 0` (not
  yet scheduled), so they have no populated `cc_engine_slug`/`cc_sort_order`.
  Resolves when scheduled. No action needed.

---

## 5. Lessons recorded

- **Project Knowledge copies of populators/source can be STALE.** Twice this
  session PK lagged the deployed source: the lost Admin edits, and the
  `Populate-AssetRegistry-HTML.ps1` subheader check. When drift behavior or
  source contradicts expectation, pull the LIVE file from the GitHub manifest
  (cache-busted) before reasoning -- the populator-as-deployed is authoritative,
  and PK is a possibly-lagging mirror. Do not design against a PK snapshot for
  shell/populator work.
- **Lost in-session edits are a real failure mode.** When a page is deferred
  across sessions, edits made but not delivered/applied can vanish. On resume,
  SYNC the working copy to the actual deployed file (re-upload) before layering
  new edits -- never assume the working copy reflects production.
- **Keyframe names are not prefix-governed; references need no resolver.**
  `@keyframes` may only be DEFINED in shell FOUNDATION, but names live in a
  global namespace and pages consume them freely via `animation:`. Confirmed
  against both the live shell (mixed prefixed/unprefixed names, all clean) and
  Sec. 11.
- **`cc-default` is not a class.** Default tier = absence of a modifier. The base
  construct rule provides the default; modifiers only override. Same pattern for
  height tiers (default 60vh, no class).
- **Module retire = export-surface diff first.** Before retiring a shared module,
  diff its exports against the replacement. A "superset" can still hide renames
  (`Build-*` to `ConvertTo-*`) that break callers by old name. Grep every
  consumer for the old names before deleting.
- **`<button>` for clickable non-interactive elements, with UA reset.** The spec
  wants action attributes on interactive elements or overlay outer containers.
  Convert div/span to button and neutralize button chrome (`font`/`color:
  inherit; text-decoration: none;` + background/border/padding where the element
  doesn't already set them). Flex-parent context preserves layout. A&I's
  `.aai-tool-card` is the precedent.

---

## 6. Carry-forward / next-session candidates

Sessions are not scoped -- pick up whatever's highest value. No item is out of
scope; nothing is deferred except by context limit. Rough order easiest to
heaviest:

### CC conformance punch-list (what's left in the zone)
- **6.1 -- `cc-toggle-*` chrome construct** (the marquee remaining piece). Build
  a shared toggle/disclosure construct so the doc-toggle/`<details>` native-state
  CSS can migrate off page-local combinators. Multi-file: JS class-management +
  shell CSS + route markup + populator awareness, then migrate Admin's doc-
  pipeline (and any other native-toggle consumer) to consume it. Clears
  admin.css's last 9 rows. Deserves a fresh session with full context. Pull live
  `cc-shared.js`/`cc-shared.css` first.
- **6.2 -- ServerHealth fixes** (deferred-for-chrome). server-health.css hex/px
  literals (confirm token mapping against live `cc-shared.css` token block first
  -- do NOT round to nearest tier, tokenize only on true purpose match);
  ServerHealth.ps1 `MISSING_HEADER_BAR`; ServerHealth-API.ps1 4x
  `MISSING_PARAMETER_DECLARATION` (parameterize the `Invoke-Sqlcmd` here-strings;
  assess injection surface). Read the live files.
- **6.3 -- Home.ps1 full conversion** (the last unconverted page). Inline to
  four-file (route/API?/CSS/JS), chrome substitutions (`$navHtml`, `$bannerHtml`,
  `$headerHtml`, `$browserTitle`), `cc-section`/`data-cc-page`/`data-cc-prefix`
  on body, prefixed classes, separate stylesheet, `cc-shared.js` script tag, CBH
  file header, drop the `# ---` markers. Needs a `Component_Registry` row check
  (component_name, cc_prefix, section_key, route) -- Home may need a prefix
  assigned. A whole session on its own.

### Shared-foundation tidy-ups (optional, cosmetic/consistency)
- **6.4 -- Keyframe name-consistency pass.** The shell now mixes unprefixed
  legacy (`pulse`/`spin`/`fadeIn`/`page-refresh-spin`), `cc`-prefixed
  (`ccModalFadeIn`), and page-prefixed-with-tag (`adm-*` + `Page: Admin.`). A
  deliberate pass could normalize all FOUNDATION keyframe names to `cc-` and
  update every `animation:` reference platform-wide. Purely a naming-convention
  pass, not a drift fix. The `Page:` notation is the seed for deciding which are
  page-owned vs. truly shared.
- **6.5 -- Keyframe dedup.** `adm-pulse-red`/`adm-pulse-yellow`/
  `adm-pip-pulse-red`/`adm-pip-pulse-yellow` are all identical opacity pulses --
  and identical to the shell's existing `pulse`. Four of the nine could collapse
  to `pulse` (updating admin.css refs). Left verbatim this session to keep the
  relocation zero-risk.
- **6.6 -- Populator comment-condensation pass** (parked since S40). All four
  populators carry oversized doc-essays; ~1,000 removable lines in the HTML
  populator alone. Standalone work item.
- **6.7 -- `cc-last` duplicate definition** in `cc-shared.css` (~815 + ~1304),
  pre-existing, harmless, optional dedup.

### Platform / backlog (carried, unchanged)
- **6.8 -- `RBAC_ActionRegistry` rows** for write/destructive endpoints across
  pages (BDL execute/retry/template-mutation set; DM Operations launch/abort;
  Server Health kill-zombies). `Test-ActionEndpoint` is wired but fail-open until
  rows exist.
- **6.9 -- DBCC disk-alert suppression during CHECKDB** (medium; cross-component
  awareness).
- **6.10 -- Retention strategy for snapshot tables** (none anywhere today).
- **6.11 -- Per-server collection-staleness indicator on Platform Monitoring**
  (S39; dimmed "stale" tile instead of silent vanish).
- **6.12 -- Platform Monitoring token-less literals** (S39; resurface when the
  CSS populator is corrected to fire on multi-line rules, not just single-line).
- **6.13 -- B2B module** (`B2B_Roadmap.md` authoritative; investigation-first; no
  new tables/columns until the relevant investigation area resolves).

---

## 7. Session boot sequence (next session)

1. Read the instructions, then this summary (CC_Session_Summary_42).
2. `project_knowledge_search` for the active anchor docs (this summary,
   Development Guidelines, Backlog, Platform Registry) to confirm Project
   Knowledge state.
3. For any shell/populator/foundation work, request a cache-busted manifest URL
   and `web_fetch` the LIVE file. PK lags deployed source -- confirmed twice in
   S42. Do not design against PK snapshots of `cc-shared.*` or the populators.
4. Pick the next item (likely 6.1 toggle construct, 6.2 ServerHealth, or 6.3
   Home). For a construct build: read ALL consumers + the relevant spec
   end-to-end before designing (S40 lesson). For ServerHealth literals: confirm
   token mapping from the live token block. For Home: confirm/assign its
   `Component_Registry` row.
5. Byte discipline on every delivery: no BOM, pure ASCII, single trailing
   newline, CRLF everywhere. Python edits leave LF -- re-normalize before
   delivery.
6. Full drop-in files at output (never patch-by-line); in-place edits to working
   copy are fine; keep the working copy cumulative across multiple edits.

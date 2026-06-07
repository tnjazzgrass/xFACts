# Admin Page Refactor Guide

A page-specific companion to the four CC specs for converting the Admin page
(`/admin`) to the CC File Format. The specs remain the sole authority; this
document pre-resolves Admin-specific ambiguities and flags gotchas so the
conversion session is mostly execution, not discovery. It is a summary, not a
line-by-line script -- the next session still reads and analyzes the four files
in full.

Prereq: the overlay-construct foundation (slide-up sizing, dock seam/hide,
`cc-dialog-subheader`) is built, verified, and proven on Applications &
Integration. Admin consumes that finished construct set; no foundation work
remains.

---

## 1. Scope and lift

Admin is the last CC page and is **fully unrefactored** (unlike A&I, which was
partially done). All four files are a first pass. Aggregate surface:

| File | Lines | Headline work |
|------|-------|---------------|
| `Admin.ps1` (route) | 388 | 52 inline `onclick` -> `data-action-*`; 84 ids -> `adm-` + overlay/dock id-forms; 6 slide-ups + 1 dock + engine panel -> chrome constructs; 3 inline `style=` -> CSS |
| `admin.js` | 1337 | **Largest task.** Build the `adm_` dispatch architecture from scratch; rename ~160 `Admin.*` functions -> `adm_`; convert ~38 rendered-HTML `onclick` strings -> `data-action-*` + argument attrs; rewrite 6 slide-up + 1 dock open/close to Sec. 11.5.3/Sec. 11.5.4; audit 4 `setInterval` timers |
| `admin.css` | 1229 | 29 descendant/sibling/group selectors -> Sec. 7.2 state-on-element (many interlocked with JS+markup); remove 6-panel + dock geometry now owned by chrome; one-declaration-per-line reformat throughout |
| `Admin-API.ps1` | 1579 | 15 of 27 routes lack `Test-ActionEndpoint` guards; add them. No in-route functions (good). Largest API on the platform |

**This is a single-session job only if focused.** The JS alone (dispatch build +
160-function rename + 90 onclick conversions across route and JS) is larger than
the entire A&I conversion was. Plan accordingly: JS is the critical path.

---

## 2. Construct inventory and chrome mapping

Six slide-ups (all currently `slideup-backdrop` + `slideup-panel <x>-panel`) and
one dock. Width snaps to the locked tier set (snap up; content-suggested, not
content-mandated). Panel left standardizes to the chrome default (20px). All
heights map to existing `cc-h-*` tiers -- no new height work.

| Construct | Today (w / h) | Chrome classes | Notes |
|-----------|---------------|----------------|-------|
| Engine controls | 340 / 55vh | `cc-slideup-overlay` + `cc-dialog cc-dialog-slideup cc-narrow cc-h-short` | id `adm-slideup-engine` |
| System Metadata | 780 / 60vh | `cc-dialog-slideup cc-wide` (default height 60vh) | id `adm-slideup-metadata`; **pairs with the dock** |
| GlobalConfig | 880 / 60vh | `cc-dialog-slideup cc-xwide` (default height) | id `adm-slideup-globalconfig`; 880 -> xwide(1000), approved snap |
| Schedule Editor | 780 / 60vh | `cc-dialog-slideup cc-wide` (default height) | id `adm-slideup-schedule` |
| Doc Pipeline | 560 / max90vh | `cc-dialog-slideup cc-default cc-h-max` | id `adm-slideup-docpipeline`; 560 -> default(580) |
| Alert Failures | 580 / 55vh | `cc-dialog-slideup cc-default cc-h-short` | id `adm-slideup-alertfailures` |
| Detail (meta) dock | 650 / 60vh, left 804 | `cc-dialog cc-dialog-dock cc-wide cc-dock-at-wide cc-h-default` | id `adm-dock-detail`; pairs with the wide(800) meta panel -> seam `cc-dock-at-wide`; height matches meta panel (60vh = default). **Try `cc-wide`(800); downshift to `cc-default` is a one-class change if too roomy.** |

Default-height tier note: the chrome slide-up default height is 60vh (no class
needed). `cc-h-short` = 55vh, `cc-h-max` = auto/90vh. So meta/gc/sched (60vh)
carry no height class; engine/af (55vh) carry `cc-h-short`; doc (90vh) carries
`cc-h-max`.

Header/subheader mapping per panel (all six follow the A&I pattern):
- Header: title -> `cc-dialog-title`; the `*-results-count` span and any
  header-right controls -> `cc-dialog-header-actions`; close button ->
  `cc-dialog-close`.
- Pinned strips (the `*-status` line, and for tree panels the column/header
  strip that must stay fixed above the scrolling tree) -> `cc-dialog-subheader`.
- Scrolling body (the `*-tree-list` / panel body) -> `cc-dialog-body`, keeping
  its page id (e.g. `id="adm-meta-tree-list" class="cc-dialog-body"`).
- Drop the vestigial `slideup-handle` / `handle-bar` on every panel.
- The outer `cc-slideup-overlay` carries the backdrop-close
  `data-action-click="adm-close-<panel>"`; the separate `slideup-backdrop` div
  is removed (folds into the overlay).

---

## 3. The JS architecture rebuild (critical path)

Admin's JS is structurally unlike any converted page. It is a global `Admin.*`
object (PascalCase methods) wired via `onclick="Admin.method(args)"` strings
baked into rendered HTML. There is **no dispatch table, no `adm_init`, none of
the `cc` event model**. This is a from-scratch build, not a handler rewrite.

Required work, in order:
1. **Establish the `adm_` namespace and dispatch tables.** Mirror the A&I
   pattern: `adm_clickActions` / `adm_changeActions` / `adm_keydownActions`
   const maps; `adm_init` registering one delegated listener per non-empty
   event type on `document.body`; per-event dispatchers that `closest()` the
   action element, prefix-filter on `adm-`, and route to the handler.
2. **Rename ~160 `Admin.xxx` functions -> `adm_xxx`** and update every call
   site. The `Admin` object wrapper goes away; functions become module-scope
   `adm_`-prefixed declarations.
3. **Convert ~90 inline handlers** (52 in the route + ~38 in JS-rendered HTML)
   from `onclick="...Admin.x(args)..."` to `data-action-click="adm-x"` plus
   argument attributes (Sec. 7.4) for the runtime args.
4. **Rewrite open/close** for the 6 slide-ups (Sec. 11.5.3: overlay `cc-open` -> rAF
   -> dialog `cc-open`; close via transitionend + backdrop guard) and the dock
   (Sec. 11.5.4: set body innerHTML -> add `cc-open`; close removes `cc-open`).
5. **Audit the 4 `setInterval` timers** and the dead-code/shared-migration
   sweep (standing JS-refactor rule): fetch `cc-shared.js`, scan for shared
   equivalents, remove no-caller functions.

---

## 4. Gotchas (the "never seen before" items, pre-flagged)

Every prior page hit at least one novel situation. Admin's are mostly in the JS
and the stateful CSS. Reason through these before writing.

**G1 -- `onclick` handlers carry arguments and `event.stopPropagation()`.**
Example: `onclick="event.stopPropagation();Admin.toggleProcess(123,true,'name')"`.
Conversion is not a simple action-name swap: extract the action
(`adm-toggle-process`), map each argument to a `data-action-adm-*` attribute
(Sec. 7.4), and move `stopPropagation` into the handler. Nested cases (a clickable
row whose child button has its own onclick + stopPropagation) are the Sec. 7.5
container-with-nested-interactive pattern -- the row becomes a `<button>` or the
nested control stays interactive while the container delegates. Decide the
pattern once and apply uniformly.

**G2 -- stateful descendant selectors are interlocked across CSS + JS + markup.**
~12 of the 29 forbidden selectors are state-on-parent-styling-child:
`.meta-root-row.expanded .meta-root-header`, `.gc-mod-row.expanded .gc-mod-header`,
`.gc-toggle-track.on .gc-toggle-knob`, `.gc-child-card.inactive .gc-child-name`,
`.doc-detail.ok .doc-detail-icon`, etc. Sec. 7.2 requires the state class on the
element that changes. Flattening means the JS that toggles `expanded`/`on`/
`inactive` on the parent must instead put a state class on the child, AND the
CSS selector flattens to a single compound on that child. These cannot be done
CSS-only -- plan them as CSS+JS+markup triples.

**G3 -- the other ~17 descendant selectors mostly DELETE, not flatten.**
Panel-scoped layout like `.meta-panel .meta-header-right`, `.gc-panel .meta-status`,
`.sched-panel .meta-status` exists only to scope layout inside the page-local
panels. When the panels become chrome, header-right becomes
`cc-dialog-header-actions` and status becomes subheader content -- so these
selectors are removed, not rewritten. Triage each of the 29: flatten (stateful)
vs delete (panel-scope layout now chrome-owned).

**G4 -- adjacent-sibling and group selectors hide among the descendants.**
Line ~599: `.gc-toggle-track.on + .gc-toggle-label` is a forbidden `+`
combinator (state-on-sibling). Line ~578:
`.gc-val-bit .gc-toggle, .gc-active-toggle .gc-toggle` is a forbidden group
(comma) AND two descendants in one rule. These need the same state-on-element
treatment, not just descendant flattening.

**G5 -- the hand-rolled toggle switch is a known chrome-promotion candidate, but
DO NOT promote it now.** `gc-toggle-track`/`-knob`/`-label` (on/off states) is
flagged in the backlog for post-refactor chrome promotion (`cc-toggle-*`).
Standing rule this cycle: not adding new chrome candidates. So keep it
page-local (`gc-`/`adm-` prefixed) and only make it spec-conformant (flatten the
state-on-parent selectors per G2/G4). Promotion is a separate future effort.

**G6 -- the GlobalConfig value cell has multiple stateful inline-edit / bitmask
widgets.** `renderGcValue` emits: an ALERT_MODE bitmask pair (Teams/Jira,
`v&1`/`v&2`), a BIT toggle, an inline text editor (`onkeydown` Enter/Escape),
and click-to-edit text -- all with inline `onclick`/`onkeydown`. These are
several distinct action+argument conversions in one render function. Page-
specific; keep local, convert wiring.

**G7 -- the doc pipeline uses native checkboxes and a 2-second poll timer.**
`<input type="checkbox">` step toggles plus `docPollTimer = setInterval(pollDocStatus,
2000)` with `clearInterval` on completion. The poll timer is legitimate (status
polling), not a refresh-badge pattern -- keep it, but route its binding through
`adm_init` / delegated handlers, not inline.

**G8 -- engine panel is a slide-up, not a slideout.** Despite the
`engine-slideout-body` class name, `engine-panel` is `position: fixed; bottom:0`
(a slide-up, 340/55vh). Map to `cc-dialog-slideup cc-narrow cc-h-short`, not a
slideout. The class name is misleading; trust the geometry.

**G9 -- `meta-status` class is reused across three panels.** gc and sched panels
both use `.gc-panel .meta-status` / `.sched-panel .meta-status` (borrowing the
meta panel's status class via descendant scoping). When flattening, each panel's
status becomes its own subheader content; decide whether they share one
`adm-status` class or get per-panel classes. Recommend a single shared
`adm-panel-status` page-local class to avoid three near-identical rules.

**G10 -- 84 ids, many reused as JS state hooks with `data-pid`/`data-cid`
attributes.** Rows carry `data-pid` / `data-cid` (process/config ids) that the
JS reads. Under Sec. 8 these become `data-adm-*` page-owned attributes. Don't
confuse them with `data-action-*` argument attributes -- `data-pid` is state the
JS reads on click, which per the spec should be an argument attribute on the
action element (Sec. 7.4) or a `data-adm-*` data attribute (Sec. 8) depending on use.
Triage each.

---

## 5. API (separate, mechanical)

`Admin-API.ps1`: 27 routes, 12 guarded, **15 unguarded**. Add
`if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }` as the
first line of each unguarded route's ScriptBlock (match the existing guarded
routes' exact form). No in-route HTML functions to remove. Verify each route
against the PS spec header/section/changelog rules. This file is independent of
the route/CSS/JS interlock -- it can be done first or last without coupling.

The "15 unguarded" matches the carried Session 40 note ("~16 GETs need guards").
RBAC_ActionRegistry rows may be needed for any newly-guarded action endpoints
that have no registry row yet -- verify against the registry before assuming the
guard alone is sufficient.

---

## 6. Suggested build order and session strategy

Order is flexible (no standing rule), but the interlock argues for:
1. **CSS first** -- triage the 29 selectors (flatten vs delete), establish the
   flattened state-class names the JS and markup will target. This sets the
   contract the other files follow.
2. **Route + JS together** -- they are tightly coupled (every action attribute in
   the route needs a dispatch entry + handler in the JS; every flattened state
   class needs the JS to toggle it on the right element). Build the `adm_`
   dispatch architecture, then convert constructs and handlers in lockstep.
3. **API anytime** -- independent; the 15 guards are mechanical.

Because the files deploy as a set and the page must not lose functionality,
deliver all four together at the end (as with A&I), not piecemeal.

Expected residual drift after conversion: the 2 transitional CCShared
import-shim rows (clear at the post-Admin cutover). Target everything else to
zero.

**Risk callout:** the JS dispatch build + 160-function rename is the part most
likely to overrun. If the session is time-boxed, do CSS + route + JS-architecture
first (the interlocked core) and treat the API guards as the safe
stop-and-resume point -- it is the only fully independent, mechanical piece.

---

## 7. Post-Admin (next-next session, not this work)

Once Admin is converted, the end-of-migration cutover becomes possible:
- Switch `Start-ControlCenter.ps1` startup to load `xFACts-CCShared.psm1`.
- Strip the CCShared import shims from every route (clears the 2-row-per-page
  transitional drift platform-wide).
- Retire `xFACts-Helpers.psm1` and `engine-events.css/js`.
- Then the chrome-promotion pass (toggle-switch, inline-edit) and the populator
  comment-condensation work.

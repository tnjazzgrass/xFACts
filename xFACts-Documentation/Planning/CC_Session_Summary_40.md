# CC Session Summary 40 — Overlay Construct Foundation (slide-up + dock + header-actions)

## What this session was

Set out to refactor the **Admin** page (last CC page). Discovered Admin's six
slide-up panels + detail dock had no conformant chrome to map onto — the spec
named a slide-up construct that `cc-shared.css` never implemented, and the dock
construct did not exist at all. **Pivoted** (deliberately, with Dirk's
agreement) to build the missing overlay-construct foundation first, then convert
the existing page-local consumers (File Monitoring, Applications & Integration),
*then* Admin. Admin was NOT started this session.

Net result: the foundation is built and verified against a real consumer (FLM
fully converted and compliant). A&I and Admin remain.

---

## Foundation built this session (ALL APPLIED to repo)

### Constructs (now real chrome)

1. **Slide-up** (`cc-slideup-overlay` / `cc-dialog-slideup`) — bottom-rising
   panel. Was specified in HTML spec but never implemented in CSS. Now
   implemented. Consumers: FLM console, A&I catalog, Admin's six panels.
2. **Dock** (`cc-dialog-dock` / `cc-dialog-back`) — companion panel that
   attaches beside an open slide-up, shares its backdrop, expands width-from-0,
   closed by a back button. **No outer overlay element** (rides the parent's
   backdrop) — deliberate structural asymmetry vs. the three backdrop overlays.
   Single dock per parent, content-replace. Consumers: A&I catalog-detail,
   Admin detail panel.
3. **Header-actions cluster** (`cc-dialog-header-actions`) — optional cluster
   between `.cc-dialog-title` and `.cc-dialog-close` (and after title on docks)
   holding count/status indicators and/or action buttons. Added because an
   inventory of all 9 slide-up/dock headers showed 7 of 9 carry more than
   title+close. Has `margin-right` so contents don't crowd the close button
   (chrome default, benefits all consumers).

### The sizing model — IMPORTANT correction (read before A&I/Admin)

The original design ("chrome owns motion/width-tiers; page owns left/height via
page-local overrides composed onto the chrome class") is **SPEC-ILLEGAL** and
was corrected mid-session. A page CANNOT override or compose onto a chrome
property because:
- **CC_CSS_Spec 3.1.1**: page CSS loads BEFORE `cc-shared.css` (mandated) → at
  equal specificity chrome wins all ties.
- **Every-token prefix rule** (CSS populator `PREFIX_MISMATCH`): a page-local
  compound selector must have EVERY class token page-prefixed → page cannot
  raise specificity with a `.cc-*.flm-*` compound.
- **CC_CSS_Spec 10.2** / `FORBIDDEN_CUSTOM_PROPERTY_LOCATION`: page files cannot
  define custom properties → cannot feed values into chrome `var()`.
- **CC_CSS_Spec 4.1**: "A page file does not redefine or selectively modify
  chrome classes." Resolution is a chrome amendment OR a fully page-local class.

**Therefore: ALL size/position variation is expressed as CHROME MODIFIER
classes.** Page files carry ZERO slide-up/dock sizing CSS. The route markup
selects size via modifier classes; the page CSS only styles genuinely unique
content (e.g. FLM's flip-card).

Implemented slide-up modifiers in `cc-shared.css`:
- Base `.cc-dialog-slideup`: `left: var(--size-page-padding-y)`, `width` default
  580, `height` default 60vh, translateY motion.
- Width tiers: `cc-narrow` (340), default (580), `cc-wide` (780), `cc-xwide` (880).
- Height tiers: `cc-h-short` (55vh), default (60vh), `cc-h-tall` (65vh),
  `cc-h-max` (auto, max 90vh).
- `cc-full` (left:0; right:0; width:auto) — full-viewport-width.
- Tokens: `--size-slideup-width-*`, `--size-slideup-height-*`.

LATE-SESSION DRIFT FIXES (applied to `cc-shared.css` after FLM was done):
- `COMPOUND_DEPTH_3PLUS` on `.cc-dialog-dock.cc-xwide.cc-open` — dock rebuilt to
  decouple width (tier modifier) from reveal (`transform`), per the slideout
  pattern. No selector now exceeds 2 class tokens.
- `MISSING_PURPOSE_COMMENT` on `.cc-h-tall` and `.cc-h-max` marker tokens —
  purpose comments added.
- **VERIFY: the CSS populator must be re-run to confirm `cc-shared.css` is clean.
  This was not yet confirmed at session end (Claude cannot run populators).**
  If any drift remains on `cc-shared.css`, resolve it before any page conversion.

Dock sizing — PARTIAL. Width and open/close ARE built (and were corrected late
in the session — see below): `.cc-dialog-dock` base width = default (650),
`.cc-dialog-dock.cc-xwide` = 1000, reveal via `transform: translateX` driven by
`cc-open`. This mirrors the slideout's decouple-width-from-state pattern (width
on the tier modifier, reveal on a different property) and matches JS spec
§11.5.4. All selectors are ≤2 tokens.

What the dock STILL lacks: `left` and `height`. The dock has `bottom: 0` only —
no horizontal seam position and no height. Unlike the slide-up (which got `left`
+ height tiers), the dock's `left` is the *paired panel's right seam*
(parent-left + parent-width) and its `height` matches the parent — a
cross-element relationship that must be derived from the slideout precedent and
verified against the populator, NOT assumed. This is the real remaining dock
gap and is open for next session.

LATE-SESSION CORRECTION (important): the dock was first built animating by
`width` (0 → N), which forced a 3-token compound `.cc-dialog-dock.cc-xwide.cc-open`
→ `COMPOUND_DEPTH_3PLUS` drift (CSS spec §7 caps compounds at 2 tokens). Fixed by
copying the slideout pattern exactly: width is a pure tier modifier, reveal is a
separate `transform` property. Lesson: the slideout is the canonical precedent
for ALL overlay sizing/animation — model new constructs on it line-by-line
rather than inventing mechanisms.

### Spec amendments (applied)
- HTML 5.4 reframed (backdrop overlays vs. dock); 5.4.5/5.4.6 dock template+rules;
  5.4.4/5.4.6 optional header-actions; 14.2 (`cc-dialog-dock`, `cc-dialog-back`,
  `cc-dialog-header-actions`); 15 (`MALFORMED_DOCK_STRUCTURE`, `MALFORMED_DOCK_ID`).
- JS 11.5.4 (dock open/close/content-replace); 11.5.5 rules (slide-up follows
  11.5.3; dock close is back-button only).

### Populator changes (applied)
- **HTML populator**: dock support — 2 drift codes; dock-ID in `Get-OverlayIdInfo`;
  dock-class in `Get-OverlayKindFromClass`; new `Test-DockConstructStructure`;
  dock branch in `Invoke-OverlayPostWalkValidation`; header-actions = both
  validators now accept 2-or-3 header children; comment-accuracy fixes.
- **CSS + JS populators**: NO changes needed (generic validators) — verified.

---

## Pages

### File Monitoring — DONE, compliant (drift = 2 expected transitional rows)
- Console converted: page-local `flm-console-overlay`/`-panel` → `cc-slideup-overlay`
  + `cc-dialog cc-dialog-slideup cc-full cc-h-tall`. Full-width, 65vh.
- Flip + Add buttons → `cc-dialog-header-actions`. Vestigial drag-handle dropped.
  Flip-card 3D mechanism kept page-local inside `cc-dialog-body`.
- Open/close rewritten to 11.5.3 pattern (rAF + transitionend).
- Backdrop fade DROPPED (was page-local, illegal — referenced `cc-open`; and no
  other overlay fades, so dropping is consistent). Dimmer is instant (matches slide).
- **Bug fixed**: monitor-list column header was scrolling; now `position: sticky;
  top:0` (page-local, legal). Servers-face header N/A for now (single entry).
- Cleared the original `flm-close-console` ACTION_ON_NON_INTERACTIVE_ELEMENT drift.

### Applications & Integration — NOT done (deferred to next session)
Blocked on TWO things, both must be built first:
1. **Dock `left` + `height`** (see foundation section) — dock width tiers and
   open/close are built; only the seam position (`left`) and `height` remain
   before catalog-detail dock can convert.
2. **`cc-dialog-subheader` amendment** (NEW, not yet built) — A&I's catalog panel
   has a mode-selector + status strip that must stay PINNED above the scrolling
   body. Chrome `cc-dialog-body` IS the scroller (`flex:1; overflow-y:auto`), so
   folding pinned strips into it fails (they'd scroll). Page-local override is
   illegal (same cascade reason). Needs a chrome `cc-dialog-subheader` region
   between header and body that stays fixed while body scrolls. Multi-consumer
   justified (A&I needs it; FLM's analogous need was solved page-locally with
   sticky, but a true dialog-level pinned region is reusable). This is a real
   spec+CSS+populator amendment (validators' header→body child-check must allow
   optional subheader between them) — do it properly, verify, don't rush.

A&I conversion plan once unblocked:
- Catalog panel: `cc-slideup-overlay` + `cc-dialog cc-dialog-slideup cc-wide cc-h-short`
  (780 / 55vh). Drop vestigial handle. Mode-selector + status → `cc-dialog-subheader`.
  Keep inner list ID `aai-catalog-body` (8 JS refs depend on it).
- Catalog-detail: `cc-dialog-dock` (1000 wide → dock `cc-xwide`, 55vh). Count span
  → header-actions. Status strip → into dock body or its own subheader (decide).
- Clears the 2 `aai-close-catalog` ACTION_ON_NON_INTERACTIVE_ELEMENT drift rows.

### Admin — NOT started (the original target; now fully unblocked once A&I patterns proven)
- Six slide-ups: engine (`cc-narrow cc-h-short`), meta (`cc-wide cc-h-tall`?? verify
  — was 60vh so `cc-h-default`), gc (`cc-xwide`), sched (`cc-wide`), doc
  (`cc-h-max`), alerts (`cc-h-short`). Count spans → header-actions.
- Detail panel → `cc-dialog-dock`. Drop vestigial drag-handle.
- Full four-file refactor (route/API/CSS/JS) per the CC File Format Initiative —
  API already clean-ish (27 endpoints, 16 GETs need Test-ActionEndpoint guards,
  no in-route functions). 103 IDs reprefix to `adm-`. ~52 onclick→data-action-click.

---

## Next-session order (resume here)
1. **Dock `left` + `height`** in `cc-shared.css` — the only remaining dock gap
   (width tiers + open/close already built). The dock's `left` = paired panel's
   right seam, `height` = matches parent. Derive from the slideout precedent and
   the parent/child relationship; verify against the CSS populator before relying
   on it. Do NOT assume an approach — work it out from the spec.
2. **`cc-dialog-subheader` amendment** (spec + cc-shared.css + HTML populator
   validators + verify). The one remaining foundation gap.
3. **A&I conversion** (consumes 1 + 2; validates dock + subheader on a real page).
4. **Admin** — the four-file refactor, consuming the now-complete construct set.

## Parked
- **Populator comment-condensation pass** — all four populators have oversized
  doc-essays; condense to meaningful 1–3 line comments. Est. ~1,000 lines out of
  the HTML populator alone. Standalone work item.
- `cc-last` duplicate definition in `cc-shared.css` (lines ~815 + ~1304) — pre-
  existing, harmless (no drift code), optional dedup.

## Lessons (this session specifically)
- **Read the full spec before designing across it.** The page-local-override
  model was built without reading CC_CSS_Spec 3.1.1 / 4.1 / 10.2 and was illegal;
  cost a deploy round-trip on FLM. Chrome-modifier model is the verified-correct
  pattern and generalizes to all consumers.
- **Design constructs against ALL consumers, not one** (the backlog said this).
  Inventorying all 9 headers caught the header-actions gap; FLM+A&I together
  justified the subheader. One-consumer evidence is not enough to amend chrome.
- Verify populator/cascade outcomes against the actual rules before asserting
  them, not from memory.

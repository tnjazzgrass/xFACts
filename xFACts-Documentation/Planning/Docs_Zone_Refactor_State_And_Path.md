# Docs Zone Refactor - State and Path Forward

Backlog: B-044. Third and final zone (after CC and standalone). This is the
current grounded state plus the decided path forward.

This revision **supersedes the prior version of this same doc**, whose path
forward was built on assumptions this session disproved. The prior doc framed the
remaining work as "a docs-zone JS spec branch plus a class-name catchup, with
nav.js refactored in place." That framing is now obsolete (see Section 1). The
real remaining work is a **navigation re-architecture**: one centrally-owned,
injected sidebar replacing four divergent per-page navs.

The specs remain the sole authority on how files are written. This is a planning
anchor, not a spec.

---

## 0. The reframe that drives everything below

The docs site was built in isolation, page-type by page-type, over a long period:
narrative pages first (from old "how it works" docs), then the dynamic reference
page, then architecture pages, then ERD/flow rendering, then CC-mockup pages. Each
page type was added when a new need surfaced, built against whatever existed at
the time, not leaning on a shared foundation - because no shared foundation
existed (the CC shared architecture was itself a later afterthought).

The consequence: **there is no design intent behind the divergences we keep
finding.** Four different nav implementations, hardcoded inconsistent footers,
per-page script includes - none of it was decided; it accreted. So the correct
posture for the remaining work is not "carefully reconcile four things" but
"build the single centered thing the site would have had if the shared
architecture had existed when it started." Replace, don't preserve. Scrap dead
code entirely.

This same principle answers any future shared-content question on this site: one
owner, one edit point.

---

## 1. What this session changed (corrections to the prior plan)

### DONE and verified THIS session (the nav vertical slice)
- **The nav sidebar vertical slice: BUILT, spec-verified, drift-clean, deployed on
  serverhealth.html.** Three files: docs-base.css (shell chrome restructure),
  nav.js (near-total rewrite), serverhealth.html (first narrative conversion). Full
  as-built detail in Section 2 and Section 4. First populator run surfaced 6 drift
  rows; all 6 resolved (Section 4).
- **localStorage spec-legality: RESOLVED** (denylist permits it, no amendment;
  populator-clean - see Section 2).
- **Fixed-header design, hub-via-brand, extensible generated footer: all settled**
  (Section 2).
- **Two new backlog items drafted** (Dirk to paste, then bump Next ID to B-095):
  - **B-093** (Catalog / ControlCenter.Shared / Investigate): evaluate capturing
    capability-API usage (network `fetch`/XHR, WebSocket, storage, timers) in the
    catalog - currently NOT captured (the populator's call-capture is selective BY
    DESIGN - it emits rows only for cross-reference payload, drift signals, and
    platform def/usage; runtime built-ins like localStorage carry none and emit
    nothing, which is correct under current criteria). Network calls the strongest
    candidate. Surfaced from the localStorage question.
  - **B-094** (Catalog / ControlCenter.Shared / Build): audit all four populators'
    capture coverage and document it in the Development Guidelines (a "what each
    populator does and does not catalog, and the criteria" section), so the
    implicit capture criteria are knowable without reading populator source.
    Distinct from B-008 (which generates pages from catalog DATA; this documents
    the populators' SELECTION LOGIC).
- **HTML spec read in full** - ~80% is CC-page-shell-specific and does not apply to
  static docs pages; the universal subset (prefix discipline, ID/class value rules,
  comment format, no inline style/script/on*, cross-spec resolution) is what we
  build docs pages to. CONFORMANCE stays manual; cross-file RESOLUTION still needs
  a tiny docs-HTML cross-reference extractor eventually (Section 3) - the no-drift
  rule means docs HTML's class/file references must be catalogued, not invisible.
- **`doc-card` consolidation confirmed**: the hub's module grid reuses the shared
  `doc-card` component in docs-base (NOT a hub-specific `doc-module-*` family - that
  was a naming error, now fixed). The shared card lives in docs-base CONTENT:CARDS.

### DONE in PRIOR sessions (still-true context, not this session)
- **JS spec docs-zone branch: written and deployed.** Seven amendments to
  `xFACts_JS_Spec.md` (4.2/4.3 zone-shell generalization, new 4.4 docs-shell
  taxonomy `IMPORTS/FOUNDATION/STATE/FUNCTIONS`, 7.2 engine-processes scoped to
  cc, 8 lifecycle-hooks scoped to cc, 11 page-boot made zone-aware, 18
  DUPLICATE_FOUNDATION generalized). 17 corrected to describe real resolver
  scope (same zone AND same component family OR chrome family).
- **JS populator docs-zone branch: deployed.** `Populate-AssetRegistry-JS.ps1`
  gained the docs-shell section taxonomy (explicit third valid-section-type set,
  zone-aware 3-way selection), engine-processes validation gated to the cc zone,
  stale MISSING_PAGE_INIT comment corrected.
- **Shared-functions single-section bug: fixed.** `Get-SectionForLine` in
  `xFACts-AssetRegistryFunctions.ps1` now normalizes its `$Sections` param via
  `@()` so a file with exactly one section banner resolves correctly (PowerShell
  collapses single-element lists). Surfaced by docs-shared.js, the first
  single-section file in the platform. No-op for multi-section files. Protects
  all four populators.
- **docs-shared.js: built, registered (scope_tier SHELL, Documentation.Site),
  drift-clean.** Holds `doc_esc` (consolidated escaper, div-trick form) and
  `doc_fetchJson` (shared async JSON loader). Note: the docs zone is monolithic
  (one component, `Documentation.Site`), so same-family resolution covers all
  cross-file references; the cc `ControlCenter.Shared` chrome-family hatch is not
  needed for docs unless the zone ever fragments into multiple families.

### What the prior plan got wrong (now corrected)
- **"CSS layer is DONE."** False going forward. The narrative + architecture CSS
  is refactored, BUT the nav re-architecture requires *replacing* the breadcrumb
  nav families: the `doc-nav-*` breadcrumb rules in docs-base.css and the
  `doc-section-nav-*` rules in docs-architecture.css are being scrapped and
  replaced with the new sidebar family. And docs-reference.css is **entirely
  un-refactored** (old header, old `--var` tokens, old `.sticky-nav-*`/`.current`/
  `.sep` classes, forbidden `:has(*)` selector). So CSS is NOT done.
- **"nav.js refactored in place via JS-CATCHUP-CONTRACT."** Obsolete. nav.js was
  structurally refactored this session (IIFE unwrapped, `doc_`-prefixed,
  sectioned, async self-boot) - but that work is now superseded by the nav
  re-architecture. nav.js is being rewritten to own and inject the sidebar
  chrome. The JS-CATCHUP-CONTRACT.md class-rename list is largely **obsolete**:
  we are not catching up four nav vocabularies, we are building one new one. (The
  non-nav class renames in that doc - for ddl-erd/ddl-loader/docs-controlcenter -
  may still have residual value for those files' eventual refactors; the nav.js
  section of it is dead.)
- **"No HTML populator exists."** Partially false, but the distinction matters.
  `Populate-AssetRegistry-HTML.ps1` exists - but it parses HTML *embedded inside
  PS files* (CC pages), NOT standalone `.html` files. The docs static HTML pages
  are catalogued by no populator; their conformance is a manual cross-check. The
  CC populator does inject nav via `$navHtml` interpolation into a PS-generated
  page shell - relevant as CONCEPT (centralized one-owner nav) but not as
  mechanism (docs nav is client-side JS injection into a static mount, not
  PS-side interpolation). See Section 3.

---

## 2. The architecture: one centrally-owned sidebar nav (BUILT AND VERIFIED)

This is no longer a plan. The vertical slice is built, spec-verified, drift-clean,
and deployed on `serverhealth.html` (the first narrative page). The contract below
is the as-built reality.

### Design contract (built, validated live)
- **Sidebar**, vertical rail of all modules. No wrapping at any module count (the
  core failure of the old top-strip nav).
- **Expanded by default.** Collapses to a ~52px icon rail on demand.
- **Collapse state persists across pages** via `localStorage` (key
  `docNavCollapsed`). SPEC-LEGALITY RESOLVED: the JS spec section 15 is a DENYLIST
  by design; localStorage is not forbidden, so it is permitted - NO amendment
  (adding an allow to a denylist would be a category error and invite bloat).
  Populator-clean: the `FORBIDDEN_WINDOW_ASSIGNMENT` check is AST-assignment-shaped
  and only fires on top-level `window.X = ...`; a `window.localStorage.setItem(...)`
  call is a CallExpression and cannot trip it (verified against the populator).
- **Active module expands inline** to its sub-pages (Overview / Architecture /
  Reference / CC Guide) in the expanded rail; kept as a secondary affordance.
- **Sticky.** The rail and the header are fixed; only the body scrolls (verified
  live). Delivers the hard requirement: nav stays anchored while ref pages
  auto-scroll to selected DDL content.
- **Sub-pages derived from existence** - registry + HEAD-probe for
  `-arch`/`-ref`/`-cc`, same data source as before.

### Fixed header (settled this session, replaced the old in-flow header)
- The page header is a NON-scrolling fixed region: page title, then subtitle, then
  the four sub-page links, in that order. Links BELOW the title was a deliberate
  choice over links-at-top - links-below read as "options for THIS page,"
  links-at-top read as global nav (Dirk's call, validated against a side-by-side
  mockup).
- Title and subtitle stay AUTHORED per-page (page-specific content). The sub-page
  links row is INJECTED by nav.js (existence-discovered) into a
  `.doc-subpage-links` mount inside the header.
- Tradeoff accepted: the fixed header permanently costs ~90-110px of vertical
  space; kept tight for that reason.

### Hub reachability (settled this session)
- The hub (index.html, "xFACts Secrets Revealed") was missing from the rail
  because the old code skipped `sortOrder === 0`. With a persistent rail it must be
  reachable. RESOLVED: the rail BRAND links to the hub (Option 1 - logo-goes-home
  convention), with a home glyph (U+2302) and the hub title as the brand text. No
  separate home row. Survives collapse (the brand mark stays as the icon-rail
  head). This also covers the back-to-hub job after the footer back-link was
  removed.

### Ownership: nav.js owns and injects the entire chrome
- nav.js injects the full sidebar rail, the header sub-page link row, AND the
  footer into mount points. Each page carries only mount-point divs - a
  `<nav class="doc-nav">`, a `.doc-subpage-links` div in the header, and a
  `.doc-footer` div - not authored nav/footer markup. One owner, one edit point.
- Collapses the ~80-page HTML change to a uniform mechanical transform (see the
  narrative-page conversion procedure in Section 4A).

### Footer: generated, extensible, Contributing-anchored (settled this session)
- The footer is nav.js-GENERATED, not authored per page. The old back-to-hub link
  and attribution line are GONE (the rail brand covers back-to-hub; attribution
  was dropped).
- The footer's content is the **Contributing callout**, which was previously
  authored into every page. It is now centrally generated by nav.js
  (`doc_buildContributing`) and reuses the shared `doc-callout doc-tip` styling.
- EXTENSIBILITY (Dirk's forward-looking requirement): `doc_buildFooter` assembles
  an ordered array of optional UPPER blocks, then always appends the Contributing
  anchor LAST. To add footer content later (e.g. bring page-links back), push a
  block-builder result onto `upperBlocks` in that one function - it flows to every
  page on next load, zero page edits, and Contributing stays pinned at the bottom.
  Level-1 design (ordered blocks above a fixed anchor), deliberately not a
  data-config system - a footer does not need that machinery.

### State-on-element collapse (CSS spec requirement, shaped the JS)
- The CSS spec section 14 forbids descendant combinators, so the prototype's
  "`.doc-nav-collapsed .label`" cascade is illegal. The collapse is implemented
  STATE-ON-ELEMENT: nav.js toggles `doc-nav-collapsed` directly onto EVERY affected
  element (rail, head, brand, brand-text, each module-link, icon, label, chevron,
  subpages) via `doc_applyCollapse`, and the CSS uses class-on-class compounds
  (`.doc-nav-head.doc-nav-collapsed`). Each state token (`doc-nav-collapsed`,
  `doc-nav-active`, `doc-nav-current`) has its own empty single-class definition
  with a purpose comment (section 7.1 requirement, or `UNDEFINED_CLASS_USAGE`
  fires). This pushed more state management into nav.js but is spec-correct and
  more robust than a cascade.

---

## 3. Open questions to resolve before / during the build

- **localStorage spec-legality** (Section 2) - verify in the JS spec before
  building collapse persistence.
- **CC `$navHtml` injection model (concept only, not a mechanism to copy)** - the
  existing `Populate-AssetRegistry-HTML.ps1` parses HTML *embedded inside PS
  files* (CC pages where PS generates markup and interpolates `$navHtml` into a
  page shell). It does NOT parse standalone `.html` files. The docs pages are
  static `.html` files whose nav is injected CLIENT-SIDE by nav.js into a mount
  div - a fundamentally different mechanism from PS-side `$navHtml` interpolation.
  So study the CC pattern for the *concept* (centralized one-owner nav) but do not
  treat it as a template; the docs mechanism is browser-side JS injection, not
  server-side PS interpolation.
- **Static-HTML populator - DEFERRED, and likely mooted by the nav work.** No
  populator catalogs the docs static `.html` files today (the existing 6000-line
  HTML populator only handles HTML-in-PS). Docs HTML conformance has always been a
  manual cross-check. Do NOT bolt docs-HTML parsing onto the existing monster -
  it is purpose-built for PS-interleaved HTML and threading a second parse mode
  through it would be the wrong kind of complexity. A separate scaled-down static
  populator was floated, but the nav re-architecture likely removes the need: once
  the nav and footer markup move INTO nav.js (catalogued by the JS populator),
  the per-page docs HTML shrinks to head + wrapper + content + two mount divs +
  scripts. The complex, drift-prone surface (the nav) leaves HTML entirely. The
  residual (page content classes, mount-div IDs) is small and stable; the existing
  manual cross-check likely suffices. Decision: defer, revisit only if residual
  uncatalogued HTML surface proves substantial after the nav work. NOT a blocker
  for the nav build.
- **HTML spec applicability to docs pages (read in full this session).** The
  existing `xFACts_HTML_Spec.md` is ~80% CC-page-shell-specific and does NOT apply
  to static docs `.html` files. The inapplicable bulk: Section 1 (PS page shell
  with `$browserTitle`/`$navHtml`/`$headerHtml`/`$bannerHtml` substitutions),
  Section 2 (`cc-header-bar`/`cc-engine-row`/`cc-refresh-info` chrome), Section 3
  (exactly-two-CSS + single `cc-shared.js` asset model), Section 5.4 (`cc-dialog`
  overlay family), Section 7 (`data-action-*` dispatch-table system), Section 11
  (helper-emitted fragments tied to `xFACts-CCShared.psm1`), Section 14 (`cc-`
  chrome reference). Docs pages have none of this - no PS shell, own `<head>` with
  N stylesheets, load `nav.js` directly, `doc-` prefixes. The UNIVERSAL subset
  that DOES apply to any HTML and should be honored as the docs "best practices"
  we build to: Section 4 prefix discipline (docs uses `doc-`/`doc`), Section 5.3
  ID value rules (lowercase/digits/hyphens, unique, no cross-prefix collision),
  Section 6.1 class value rules (lowercase/digits/hyphens, single-space, no dupes),
  Section 9.1 text/user-facing-attribute rules (no empty `title`/`alt`/etc.),
  Section 10 comment format (76-`=` divider, no `--`, closed), Section 12 universal
  trio (no inline `style=""`, no inline `<style>`, no `on*` handlers), Section 13
  cross-spec resolution (CSS class/file refs and JS file refs resolve against the
  catalog - this one genuinely applies, docs pages reference docs CSS/JS).
  VERDICT: build the new mount-point HTML and nav.js-injected markup to this
  universal subset from the start (we would anyway - it is just good hygiene), so
  we never generate CONFORMANCE drift. CONFORMANCE (well-formedness per the rules)
  can stay a manual cross-check. BUT cross-file RESOLUTION cannot - see next item.
- **Docs-HTML cross-reference cataloging - a tiny extractor IS likely needed.**
  Distinct from conformance. The no-long-term-drift rule is absolute: unresolved
  cross-file references are drift, and the catalog is the source of truth for
  cross-file dependencies. Today the docs static HTML is invisible to every
  populator - so its `class="doc-*"` CSS-class refs, its `<link>` CSS-file refs,
  and its `<script src>` JS-file refs are neither resolved NOR drifting; they are
  simply absent. That absence is a HOLE in the catalog, not a clean state. The nav
  work shrinks the residual (nav/footer identifiers move into nav.js, catalogued
  by the JS populator) but does NOT zero it: page content still carries container
  classes (`doc-section`, `doc-callout`, `doc-info-table`, mount-div classes) and
  pages still reference their CSS/JS. Those references SHOULD resolve and currently
  cannot. So a second docs-HTML populator is likely warranted - but a DRAMATICALLY
  scaled-down one whose ONLY job is to emit the three Section 13 cross-spec USAGE
  row types (CSS class refs, CSS file refs, JS file refs) so the existing resolve
  phase matches them against the docs CSS/JS DEFINITIONs already in the catalog. NO
  conformance machinery (no page-shell checks, no chrome validation, no
  overlay/dispatch-table rules - none of the inapplicable 80%). It emits no drift
  codes of its own beyond the three `*_UNRESOLVED` the resolver already stamps. A
  genuinely small cross-reference extractor, NOT a parallel of the 6000-line CC
  HTML populator. Do this AFTER the nav work (so it catalogs the reduced, final
  HTML surface, not markup we are about to delete). Decision: build the tiny
  cross-reference extractor; it is the honest way to close the catalog hole
  without the conformance-enforcement weight.
- **Module ordering** - the sidebar order is registry-driven (`sortOrder`). Dirk
  wants to change per-page/per-module nav ordering and "a few other minor things";
  these fold naturally into defining the new nav's behavior, handled as we build.
- **HTML populator docs branch** - if the docs pages adopt a mount-point shell,
  the HTML populator likely needs a docs-zone branch for whatever the docs page
  shell contract becomes (mount divs, script includes, docs-shared.js include).
- **docs-shared.js include across pages** - once ddl-erd/ddl-loader adopt the
  shell (`doc_esc`/`doc_fetchJson`), their pages must load docs-shared.js before
  the consumer. nav.js was deliberately kept self-contained (its own
  `doc_fetchRegistry`) to avoid forcing the docs-shared.js include onto all ~80
  pages just for nav. The ddl files load on far fewer pages, so their include is
  a contained change. (Adopting a shared helper is an HTML change, not just JS.)

---

## 4. Build status: ALL FRONT-LINE PAGES DONE

The shell (docs-base.css), nav.js, and every front-line page are complete,
spec-verified, and deployed. Front-line set = 16 narrative pages + the hub
(index.html) = 17 pages. As-built status:

1. **docs-base.css (the shell)** - DONE. The old breadcrumb `doc-nav-*` family and
   the old page-header/footer/page-wrapper families are GONE (replaced, no dead
   code). New CHROME sections: APP FRAME (the flex viewport frame), SIDEBAR
   NAVIGATION, FIXED HEADER, and a slim generated-footer container. The layout
   folded into CHROME (not a shell LAYOUT section) - more spec-correct, since
   universal frame IS chrome, and the spec has no rule forbidding shell LAYOUT
   anyway (the section-4 "Where it lives" column is descriptive, not enforced; no
   drift code exists for LAYOUT-in-shell - confirmed against the drift table).
   Tokens added: `--size-nav-width` (240px), `--size-nav-collapsed` (52px),
   `--size-nav-head` (52px). Verified: banner geometry, FILE-ORG match, section
   order, no forbidden selectors, every state-token compound resolves, byte-clean.
2. **nav.js** - DONE. Near-total rewrite: builds the rail, injects header sub-page
   links, generates the extensible Contributing-anchored footer, toggles collapse
   state-on-element with localStorage persistence, brand links to hub. Preserves
   the working registry-fetch / page-detection / existence-check discovery.
   `doc_buildHubCards` is GATED to `doc_filename === 'index.html'` so it only
   auto-populates the hub's module grid; authored `.doc-card-grid` content on other
   pages (e.g. tools.html's BDL Import Guide card) is never overwritten. Verified:
   section/declaration rules, the nested closure-IIFE is exempt (populator only
   flags TOP-LEVEL IIFEs - confirmed), byte-clean.
3. **All 16 narrative pages** - DONE via the uniform transform in Section 4A:
   serverhealth, controlcenter, backup, batchops, bidata, dbcc, dmops, engine-room,
   fileops, indexmaint, jboss, jira, jobflow, replication, teams, tools. Each
   verified: mounts present, old elements removed, section/callout counts preserved
   vs original, byte-clean, hygiene-clean. Structural outliers handled: controlcenter
   (extra info callouts), fileops (`+` in trailing comment, inline body links,
   side-by-side blocks, code tables), tools (authored content card grid), jira
   (inline cross-links). The transform cuts at the EARLIEST trailing-block marker
   from a robust set (handles the `+`-vs-`&` comment variant).
4. **index.html (the hub)** - DONE. Hub-specific transform: keeps docs-hub.css (NOT
   docs-narrative.css), preserves the markup title (`x<span class="doc-fac">FAC</span>ts...`
   - NOT flattened), keeps the auto-populated `.doc-card-grid` empty-with-comment
   (nav.js fills it, now correctly via the gate), preserves the architecture
   diagram / pattern flow / tech-stack table. All 9 sections preserved.
   LESSON: the hub has a `doc-callout doc-tip` IN ITS CONTENT (the philosophy tip),
   so cutting at the first `doc-tip` div truncated the page. Fix: cut at the
   `<!-- Contributing -->` COMMENT marker, which only appears at the trailing block.
   The byte count (5.6KB vs expected ~16KB) caught it - verify output SIZE, not just
   structure.

### Drift from the first populator run (vertical slice) - ALL RESOLVED
- `MISSING_BLANK_LINE_SEPARATOR` (footer banner joined to body with no blank line)
  - my assembly bug, fixed. (My own verification missed it - I checked for EXCESS
  blank lines, not MISSING ones. The populator caught what I did not. Lesson:
  verify both directions.)
- `DRIFT_PX_LITERAL` (52px on `.doc-nav-head`) - tokenized as `--size-nav-head`.
- 4x `JS_CSS_CLASS_UNRESOLVED` (`doc-module-card`/`-grid`/`-title`/`-desc`) - these
  names existed NOWHERE; invented when prefixing the old unprefixed `module-card`.
  The hub's module grid actually reuses the shared `doc-card` component in
  docs-base. Fixed `doc_buildHubCards` to emit `doc-card`/`doc-card-grid`/
  `doc-card-title`/`doc-card-desc`.
- NOTE: the narrative-batch pages and the hub were converted AFTER the slice
  drift-run and have NOT yet been through the populator as of session end. Same
  transform that produced the drift-clean slice, so expected clean; confirm on the
  next populator run. Any drift would likely be uniform across the batch.

## 4A. Narrative-page conversion procedure (reference - the rollout is COMPLETE)

All narrative pages share one structure, so conversion was a uniform mechanical
transform. `serverhealth.html` is the reference. Per page:

1. **`<head>`** stays as-is: loads `../css/docs-base.css`, `../css/docs-narrative.css`,
   and (at body end) `../js/nav.js`. No change.
2. **Wrap the body in the app frame**:
   `<body><div class="doc-layout">`.
3. **Rail mount** as first child: `<nav class="doc-nav"></nav>` (empty - nav.js
   fills it).
4. **Content column**: `<div class="doc-content">`.
5. **Fixed header** with AUTHORED title/subtitle + links mount:
   ```
   <div class="doc-header"><div class="doc-header-inner">
     <h1 class="doc-page-title">PAGE TITLE</h1>
     <div class="doc-page-subtitle">PAGE SUBTITLE</div>
     <div class="doc-subpage-links"></div>   <!-- nav.js fills -->
   </div></div>
   ```
   The title/subtitle come from the page's OLD `.doc-page-header` (now removed).
6. **Scrolling body** holding all the existing content:
   `<div class="doc-body"><div class="doc-body-inner">` ... existing context bar,
   sections, etc. ... `<div class="doc-footer"></div>` (footer mount, nav.js fills)
   then close `</div></div>`.
7. Close `</div>` (content), `</div>` (layout), then the `<script>` tag.
8. **REMOVE from the old page**: the old mid-page `<div class="doc-nav"></div>`
   breadcrumb, the old `.doc-page-header` wrapper (its title/subtitle move to the
   fixed header), the old authored `.doc-footer` block, the `.doc-ref-link-group`
   cross-reference button groups (retired - the top sub-page links replace them),
   and the authored Contributing callout (now nav.js-generated). The old
   `.doc-page-wrapper` is replaced by the layout/content/body structure.

Byte discipline on every output: ASCII (HTML entities, no raw non-ASCII), CRLF,
single trailing newline, no BOM. Exact production filename.

### Site-wide cleanup owed once narrative pages are all converted
- **Dead CSS in docs-narrative.css**: the `.doc-ref-link-group`,
  `.doc-ref-link-group-following`, and `.doc-ref-link` rules become dead once no
  page uses them. Remove them after the last narrative page is converted (or
  confirm no other page type uses them first). (`doc-footer-link`/`doc-footer-line`
  were already removed from docs-base.css this session.)
- The narrative pages are the FIRST set. Arch / ref / cc pages are NOT touched yet
  (different structures - ref is ddl-loader-filled, cc has strict CC fidelity).
  Convert ALL narrative pages before starting any other page type.

---

## 4B. Remaining JS work (after narrative pages)

The ddl-loader jump-link reconciliation (reference pages' object jump links
retarget into the new fixed-header structure) is handled as part of ddl-loader's
own ground-up rewrite - see Section 5.

---

## 5. Remaining docs-zone JS work (beyond the nav re-architecture)

These are the other docs JS files, still to refactor against the (now-deployed)
docs-zone JS spec branch. The nav re-architecture is the immediate focus; these
follow.

| File | Nature | Notes |
|---|---|---|
| ddl-erd.js | ES5, IIFE-wrapped, renders ERDs from JSON | Adopt `doc_esc`. Then CSS-bonded class catchup with docs-erd.css. |
| ddl-loader.js | **Full ES6** - forbidden dialect | GROUND-UP REWRITE to ES5/spec dialect, not a refactor. Adopt `doc_esc`/`doc_fetchJson`. Largest docs JS file (1200 lines). Then docs-reference.css class catchup + jump-link retarget. |
| docs-controlcenter.js | ES5, IIFE, drives cc-mockup interactivity | Structural refactor. Phase C (cc-mockup pages, last - strict visual fidelity to real CC). Does NOT do nav. |

The two remaining CSS files bonded to JS (docs-erd.css, docs-reference.css) share
a class-name contract with their JS partner and must travel with it - refactoring
the CSS renames classes that break the dynamic render until the JS matches.

---

## 6. Shelved spec-accuracy items (non-blocking)

- **Section 17 correction** - drafted this session (resolver scope is "same zone AND
  same component family OR chrome family", not just "same zone"). If not yet
  applied, apply it. The resolver tightening (cross-module false matches against
  unrelated LOCAL definitions) was a real fix the spec never documented.
- **"canonical" cleanup in `Resolve-AssetRegistryReferences.ps1`** - the resolver
  uses the banned word "canonical" twice (lines ~31, ~552: "HTML is the canonical
  source of truth for ID declarations"). Dirk handling directly.

---

## 7. Standing context carried forward (still true)

### ERD rendering directive
The arch pages' ERDs currently render via the OLD (un-refactored) docs-erd.css
PLUS the NEW consolidated palette, and this looks markedly BETTER than the
original (original had a blue box/frame; now clean dark-on-dark with proper
status/accent colors and a subtle hover glow). The improvement is palette-driven
(colors inherited from docs-base tokens). **When docs-erd.css is refactored,
preserve this current look** and shed any hardcoded blue-frame styling from the
original. Token-driven, so low appearance risk.

### Page-category treatment principles
- **Normal content pages** (narrative, tools, arch, ref, hub): visuals were
  emergent/loose. Consolidate and simplify. Preserve a difference only if it
  carries meaning (e.g. category-tag colors). Do NOT preserve accidental
  creative-license differences.
- **Static mockup pages** (BDL import guide): recreate UI; open question is reuse
  real CC component classes vs keep standalone `mock-*`. Decide after CC CSS
  understood.
- **Interactive mockup pages** (`*-cc.html`): STRICT visual fidelity to the real
  CC page (the real CC UI is their external spec). Highest preservation bar, most
  JS-dependent, genuinely last (Phase C). Likely reuse real cc-shared.css/JS.

### Architecture / mechanics constants
- Tree: `public/docs/` with `pages/` (+ `cc/`, `arch/`, `ref/` subfolders),
  `data/ddl/` (doc-registry.json + per-schema JSON), `css/`, `js/`.
- `doc-registry.json` is generated from `Component_Registry` doc_* columns.
- Filename conventions: `{pageId}.html`, `{pageId}-arch.html`, `{pageId}-ref.html`,
  `{pageId}-cc.html`, `{pageId}-cc-{slug}.html`.
- `ddl-loader.js` renders reference pages from per-schema JSON into `ddl-root`
  containers (`data-schema`, optional `data-category`).
- `ddl-erd.js` renders ERDs into `erd-root` containers (same data attributes).
- Component: `Documentation.Site`. Chrome prefix for the docs zone: `doc`.
- Byte discipline: no BOM, pure ASCII (HTML entities not raw chars), CRLF, single
  trailing newline. Full-file deliverables, exact production names.

---

## 8. One-line status (UPDATED 2026-06-22)

ARCHITECTURE ZONE COMPLETE. Eight files now populator-confirmed drift-clean:
docs-base.css, docs-hub.css, docs-narrative.css, docs-architecture.css, nav.js,
docs-shared.js (front-line, prior), PLUS this session ddl-erd.js and docs-erd.css
(ground-up refactors). All 15 arch HTML pages converted to the app-frame with the
new `.doc-section-jumps` header row. `doc_esc` consolidation DONE in nav.js
(consumes shared); docs-shared.js wiring on the 17 narrative pages is Dirk's
hand-paste (one `<script>` line each). JS spec amended: new sec.4.5 (docs non-shell
files follow page-file rules, declare `doc` prefix). ERD visually cleaned (neutral
table headers, standalone-grid alignment bug fixed). REMAINING: 4 files / 2 page
sets - the Reference pair (ddl-loader.js + docs-reference.css) and the Control
Center mockup pair (docs-controlcenter.js + docs-controlcenter.css). See sec.9 for
the scoped roadmap. STILL OPEN (designed, not built): the populator shadow-logic
change (Option A, zone-keyed) + JS spec sec.18 conformance - the enforcement
guardrail for the `doc_esc` class of bug. Backlog added: B-095 (duplicate-identifier
JS drift code), B-097 (radius token scale).

---

## 9. Next session: the two remaining page sets (INVESTIGATED 2026-06-22)

Architecture is complete. Four files remain, forming two bonded pairs - each a
JS-file-plus-its-CSS that must refactor in lockstep (the JS emits the classes the
CSS styles, exactly as ddl-erd.js <-> docs-erd.css). Drift counts:
ddl-loader.js 54/140, docs-reference.css 114/299, docs-controlcenter.js 45/70,
docs-controlcenter.css 301/735. All four are unrefactored ground-up files.

### Pair R - REFERENCE (ddl-loader.js + docs-reference.css). The hard JS one.
The ref pages are ~95% generated by ddl-loader.js, which emits the entire
`obj-nav-*` / `obj-badge` / `obj-type-label` / `field-table` / `card-stack` /
`object-block` / `query-*` vocabulary that docs-reference.css styles. Lockstep pair.

- **ddl-loader.js is the biggest single item in the zone: 1,200 lines, genuine
  ES6.** Scan: IIFE-wrapped, 41 `let`, 92 ARROW functions, 1,201 template-literal
  backticks, 27 nested functions, 0 top-level functions, 0 `doc_init`. (NOTE: the
  97 `class` hits are `class=` HTML attributes in template strings, NOT ES6 class
  declarations - zero real classes, which is simpler than it first looks.) The
  refactor is heavier than ddl-erd.js was: on top of the same IIFE-unwrap / prefix /
  banner / `doc_init` work, it needs ES6->ES5 conversion - every arrow to a named
  `function`, every `let` to `var`, and every template literal to string
  concatenation (the JS spec recognizes no template-literal form). Follows sec.4.5
  page-file rules, `doc` prefix, self-invoked `doc_init` (the nav.js pattern).
- **docs-reference.css (479 lines, 114 drift)** is old-architecture: old tokens
  (`--bg-*`/`--text-*`/`--accent-*`), the `sticky-nav` two-tier bar (same pattern
  arch's section-nav had - scrap it, fold jumps into the fixed header), a `:has()`
  selector (check against CSS sec.14 forbidden list), descendant combinators, and the
  un-prefixed `obj-*`/`field-*`/`card-*`/`query-*` classes -> `doc-` rename. The
  `obj-nav-*` object-jump system is the ref analog of arch's `.doc-section-jumps`,
  but DATA-DRIVEN (ddl-loader injects it from the catalog) and color-coded by object
  type - so it gets its own `doc-` family, not shared with section-jumps (the
  "object vs section" naming split already decided).
- **Ref HTML pages** author very little (the page is generated) - likely just a
  `ddl-root` mount + sticky-nav shell, analogous to arch's `erd-root`. Confirm what
  the ref HTML authors vs. what ddl-loader injects before converting.
- **Scroll-offset**: docs-reference.css has the old `scroll-padding-top: 132px`
  fallback "overridden dynamically by ddl-loader.js" - so ddl-loader currently owns
  a scroll-padding mechanism. The arch pages ended up NOT needing the offset
  function (flex-column layout handled it); verify whether ref needs it before
  porting.

### Pair C - CONTROL CENTER MOCKUPS (docs-controlcenter.js + docs-controlcenter.css).
Interactive mockups of real CC pages with guided walkthroughs. Strict visual
fidelity to the live CC UI.

- **docs-controlcenter.js (354 lines) is the EASIER JS** - ES5-clean (1 `let`, 0
  arrows), IIFE-wrapped like ddl-erd was. BUT the behavioral contract is rich and
  must be preserved exactly: tour vs. show-all mode toggle, callout-marker states
  (idle/pulsing/visited/flash), an additive slideout that builds section content as
  markers are clicked, bidirectional mock<->slideout highlighting, flip key-cards.
  The refactor is structural (IIFE-unwrap, prefix, banners, `doc_init`) PLUS an
  event-delegation rework: it currently binds listeners INSIDE loops
  (`markers.forEach(... addEventListener ...)`, flip cards, sidebar items) which JS
  sec.12.3 forbids - these must become delegated handlers on stable parents per
  sec.11/sec.12, routed through dispatch tables. That delegation rework is the real
  work here, not the dialect.
- **docs-controlcenter.css (805 lines, 301 drift) is the LARGEST CSS file in the
  zone** and the biggest single CSS effort remaining. It is an entire `mock-*`
  design system replicating real CC chrome (mock-container, mock-header, mock-agent-*,
  mock-ag-*, mock-disk-*, mock-chart, mock-modal-preview...) plus `key-*` flip-card
  machinery and `guide-slideout` panels. Scan: 67 old-token refs, 26 descendant
  combinators, 4 `@keyframes`, 2 `@media`. The `@keyframes` are the notable
  cross-file issue: CSS sec.11 permits `@keyframes` ONLY in the shell file FOUNDATION
  (docs-base.css), so the 4 keyframes here must MOVE to docs-base.css's FOUNDATION
  and be consumed by reference - a shell-file edit, not a self-contained refactor.
  Heavy descendant-combinator rework (26) per sec.7.2 state-on-element.
- **Open design question (unchanged from prior doc):** the mockups replicate real CC
  UI. Do the mock classes get a `doc-mock-*` prefix and live entirely in the docs
  zone (likely - they are docs-zone files, must be `doc`-prefixed), styled to LOOK
  like CC without sharing cc-zone classes? Almost certainly yes per sec.4.5/sec.5, but
  the visual-fidelity-vs-independent-styling tension is the thing to settle first.

### Recommended order
1. **Pair R first (ref + ddl-loader.js).** It is the harder JS but the cleaner
   conceptual story (data-driven generation, same shape as the arch/ERD pair we just
   finished - proven pattern). Sequence within the pair: docs-reference.css first
   (settle the `doc-` class names + obj-jump family), THEN ddl-loader.js (emit the
   new names + ES6->ES5 + structure), THEN the ref HTML (mount rename). Mirrors how
   the ERD pair went.
2. **Pair C second (cc mockups).** The CSS is the largest single effort in the zone
   and the `@keyframes`-to-shell move touches docs-base.css. The JS delegation rework
   is the trickiest behavioral-preservation task. Settle the `doc-mock-*` prefix
   question before starting. Genuinely the last and hardest set.
3. **The enforcement guardrail (still owed, designed not built):** the populator
   shadow-logic change (Option A, zone-keyed: cc keys on `scope`, docs on
   `scope_tier`) + the engine-events dead-code strip + JS spec sec.18 conformance
   (the stale `SHADOWS_SHARED_FUNCTION` row + missing prose rule). This is
   independent of the page work and can slot in any time. NEEDS Dirk's branch-vs-
   lookup-table decision for the zone->axis selection. Doing it closes the loop on
   the `doc_esc` class of bug for good.

### Standing principles that carried the arch work (apply to ref/cc too)
- Each JS+CSS pair refactors in lockstep; deploy atomically (CSS + JS + HTML together
  or the page renders unstyled).
- Preserve rendering/behavior byte-identically; refactor structure and names only.
  Diff the behavioral core before shipping.
- Spec-silent cases: build the way that seems right, let the populator rule on it
  (the nested-helper and cross-section-token questions both passed clean this way).
- Hook classes (`erd-root`, likely `ddl-root`) referenced by JS but styled by no
  CSS rule: give them a legitimate CSS definition (real mount-container styling),
  not an empty rule. Clears `JS_CSS_CLASS_UNRESOLVED` honestly without forcing a
  docs-HTML populator build. (The docs-HTML-populator question remains a deliberate
  future choice, not forced.)

### Do NOT
- Do NOT template from the existing pages - build to spec. (The `doc_esc`
  propagation error came from templating; that is the failure mode the rule prevents.)
- Do NOT share the ref `obj-jump` family with arch's `section-jumps` - object vs
  section, different families, different files.
- Do NOT leave the cc `@keyframes` in docs-controlcenter.css - they move to the
  shell FOUNDATION per CSS sec.11.
- TEMPLATE FROM AN EXISTING PAGE. Build every page from the spec. The doc_esc
  duplication above is exactly what templating causes. Script blocks, like
  everything else, come from the spec - not from what an old page happened to load.

# Docs Zone Refactor - State and Path Forward

Backlog: B-044. Third and final zone (after CC and standalone). This supersedes
`Docs_Zone_Refactor_StartingPoint.md`, which was the pre-work planning anchor.
That doc's CSS analysis proved correct and is now executed; its JS analysis was
incomplete (see Section 4). This doc is the current grounded state plus the
decided path forward.

The specs remain the sole authority on how files are written. This is a planning
anchor, not a spec.

---

## 1. What is DONE (this initiative, through the current session)

### CSS - the entire static-content CSS layer is refactored and drift-free
The going-in hypothesis ("specs fit, mechanical + selector-discipline cleanup,
docs-base is the shell") held exactly as predicted for CSS. Completed:

| File | Status |
|---|---|
| docs-base.css | DONE - shell file. Holds the consolidated token palette. |
| docs-narrative.css | DONE |
| docs-hub.css | DONE |
| docs-architecture.css | DONE |

All four are drift-free and deployed.

### Token palette consolidation (a substantive design win, not just cleanup)
Three color families now live in docs-base `:root`, adopted from the real CC
values in cc-shared.css so the docs match the live dashboards:
- **Status family** (5): `--color-status-success/progress/warning/critical/info`
  (green/blue/yellow/red/neutral). Drives both the alerting legend (teams) and
  the dashboard-status legend (controlcenter). Orange deliberately eliminated.
- **Accent-categorization family** (4): `--color-accent-platform/departmental/
  tools/shared` - the "what kind of thing" primary site colors (the teal is
  `--color-accent-shared`).
- **Decorative accent family** (blue/green/orange/purple/red + -rgb/-dim) - the
  random visual-variety colors the flow diagrams use. Insulated from the two
  meaningful palettes above.
Shared components built in docs-base: `doc-card` (one clickable-box-link
component replacing both guide-card and module-card), with category-tag badge
variants. `tech-table` collapsed into `doc-info-table` (was identical).

### HTML pages refactored - two full page-types complete
| Page type | Count | Status |
|---|---|---|
| Narrative | 15 + tools + index (hub) | DONE |
| Architecture | 15 (all `*-arch.html`) | DONE |

All transformed: classes reprefixed `doc-*`, inline styles absorbed into classes,
descendant-selector targets given explicit classes, byte discipline (no BOM,
ASCII via HTML entities, CRLF, single trailing newline). Class resolution
verified by hand against the CSS files (no HTML populator exists yet - Section 5).

### Tracking artifacts produced this session
- **JS-CATCHUP-CONTRACT.md** - every old->new class rename and new state class the
  docs JS must emit/toggle once the JS pass runs. The bridge between the done CSS
  and the pending JS. Grows as more pages are refactored.
- **TEMP-DRIFT-ARCH.md** - the handful of deliberately-deferred inline styles on
  three arch pages (jobflow's bespoke flow layout, dmops sub-heading spacing,
  replication ERD-container widths). Each has a named remedy. Temporary, tracked,
  not silently accepted.

---

## 2. What REMAINS

| Work | Nature | Blocked on |
|---|---|---|
| docs-reference.css + ddl-loader.js | CSS bonded to JS - refactor together | JS-spec branch (Section 4) |
| docs-erd.css + ddl-erd.js | CSS bonded to JS - refactor together | JS-spec branch (Section 4) |
| nav.js | The zone's de-facto shared JS - refactor first | JS-spec branch (Section 4) |
| docs-controlcenter.js | Drives the interactive cc guide pages | JS-spec branch + Phase C |
| Reference HTML pages (`*-ref.html`) | Thin skeletons (mostly empty `ddl-root` containers) | the reference family CSS/JS above |
| CC-mockup HTML pages (`*-cc.html`) | Interactive mockups - Phase C, last | JS pass + the reuse-vs-standalone decision |
| BDL import guide HTML | Static UI-mockup gallery (~80 `mock-*` classes) | Phase C decision (reuse real CC classes vs standalone) |
| HTML populator question | Whether to build a minimal ID/class extractor | residual `JS_*_UNRESOLVED` count after JS pass |

The two remaining CSS files (`docs-reference.css`, `docs-erd.css`) are NOT
independent refactors. They style DOM that their JS partners generate at runtime,
so they share a class-name contract with that JS. Refactoring the CSS renames
classes, which breaks the dynamic content until the JS is updated to match. They
must travel with their JS partner. This is why all remaining work is blocked on
the JS-spec branch.

---

## 3. The keystone realization: the remaining work is JS-gated

The two completed page-types (narrative, architecture) were CSS-led: prose with
styled components, where the JS (nav.js) was a thin garnish we could defer. The
entire remaining surface is the inverse - JS-led:
- **Reference pages** are ~95% JS-rendered (DDL from `data/ddl/{Schema}.json` via
  ddl-loader.js into empty `ddl-root` containers). The HTML file is a skeleton.
- **ERDs** render from JSON via ddl-erd.js.
- **CC-mockup pages** are fully interactive (docs-controlcenter.js).

So there is no more pure-content CSS/HTML to do. Everything left is either JS
itself or CSS-bonded-to-JS. The JS pass is now the only way forward, and it is
gated on a spec decision (Section 4).

---

## 4. THE DECISION THAT LEADS OFF NEXT SESSION: docs-zone JS spec branch (Option C)

### The finding
The JS spec (`xFACts_JS_Spec.md`) was written CC-first. Its architectural model
assumes: a shared shell file (`cc-shared.js`) with a BOOTLOADER that discovers
page modules and invokes `<prefix>_init`; `<prefix>_ENGINE_PROCESSES` constants
tied to `Orchestrator.ProcessRegistry`; page lifecycle hooks invoked on
WebSocket/engine events (`onEngineProcessCompleted`, etc.); and per-event
dispatch tables wiring `data-action-*` HTML attributes to handlers.

**The docs zone has none of this.** Confirmed with Dirk:
- No docs shell file exists. No init/bootloader model. nav.js currently
  self-boots (classic IIFE running on load).
- nav.js predates the current architecture - it was new functionality added
  mid-CC-refactor under an incomplete cataloguing assumption. It was never a
  parallel of the CC architecture; it is its own thing.
- Very little of the CC apparatus applies. The docs JS only: builds nav (nav.js),
  renders DDL from JSON (ddl-loader.js), renders ERDs from JSON (ddl-erd.js), and
  runs interactive-guide behavior (docs-controlcenter.js). No engine processes, no
  WebSocket hooks, no dispatch-table action wiring.

This is the misfit the OLD planning doc said did not exist. For CSS it genuinely
did not (that doc was right). For JS it does - it only became visible after the
CSS was done and nav.js was opened against the full JS spec this session.

### The decision (made): Option C - a docs-zone JS spec branch, no bootloader
Three options were weighed:
- **A** - nav.js becomes the docs shell (formalize what is already de-facto true).
- **B** - create a new `docs-shared.js` shell, nav.js stays a page module.
- **C** - amend the spec with a docs-zone branch that does NOT require the
  shell/bootloader/init-orchestration model, treating the docs zone as
  legitimately simpler than CC.

**Dirk chose C.** Rationale: forcing CC's bootloader/shell/engine machinery onto a
zone that does not need it would make the spec describe an architecture the docs
zone does not have - and then every docs JS file would carry "drift" for lacking
engine processes / lifecycle hooks it has no reason to have. That is the opposite
of a meaningful drift report. The spec discipline's whole point is that the spec
describes reality accurately so drift means something real. The docs zone is
simpler; the spec should say so. Amend the spec to define a lean, honest
docs-zone JS structure and exempt the CC-only machinery.

### What Option C entails (the next-session work, in order)
1. **Design the docs-zone JS spec branch.** Define what a docs JS file must look
   like: header + FILE ORGANIZATION, CONSTANTS / STATE / FUNCTIONS sections,
   prefix discipline (`doc_` for shared/chrome-role files per the existing
   zone->chrome-prefix map; page-prefix for any true page module), purpose
   comments, one-declaration-per-statement, `var`/`const` rules, no `let`, no
   IIFE, delegated event binding / no per-element listener loops. Define a
   docs-appropriate page-boot entry (e.g. a single `DOMContentLoaded` listener
   calling a `doc_init`-style function) WITHOUT requiring a shell bootloader.
   Explicitly exempt: ENGINE_PROCESSES, PAGE LIFECYCLE HOOKS, chrome dispatch
   tables, and the FOUNDATION/BOOTLOADER/CHROME shell-section model.
2. **Amend the populator** with the docs-zone JS branch: apply the lean rules,
   suppress the CC-only drift codes for docs-component files. Mirror the
   structure used for any existing zone branching.
3. **THEN refactor the docs JS against the corrected spec**, in order:
   - **nav.js first** - it loads on every page (de-facto shared), it is the
     simplest (no JSON-render engine), and refactoring it closes the breadcrumb
     seam on all ~30 already-shipped pages at once. JS equivalent of doing
     docs-base first. Use JS-CATCHUP-CONTRACT.md as the exact rename checklist.
   - **ERD family**: docs-erd.css + ddl-erd.js together (preserve the current ERD
     look - see Section 6).
   - **Reference family**: docs-reference.css + ddl-loader.js together, then the
     thin `*-ref.html` pages.
   - **docs-controlcenter.js** with Phase C.

This is a spec-design effort first, refactor second - deliberately teed up for a
fresh start, not begun at the end of a long session.

---

## 5. Standing context carried forward

### ERD rendering directive (Section 6 cross-ref)
The arch pages' ERDs currently render via the OLD (un-refactored) docs-erd.css
PLUS the NEW consolidated palette. Dirk confirmed this looks markedly BETTER than
the original (the original had a blue box/frame; now it is clean dark-on-dark
with the proper status/accent colors and a subtle hover glow). The improvement is
palette-driven (the colors come from docs-base tokens the ERD inherits). **When
docs-erd.css is refactored, preserve this current look** - and shed any hardcoded
blue-frame styling left from the original. The good look is already stable because
it is token-driven; the refactor is low-risk on appearance.

### HTML populator question (still deferred, unchanged)
No structural HTML populator exists. HTML conformance is currently a manual
cross-check (class resolution, byte discipline, no inline styles). The decision on
whether to build even a minimal `HTML_ID` / `CSS_CLASS` extractor is deferred
until the residual `JS_*_UNRESOLVED` count is known after the JS pass. Most pages
are inert from JS's perspective (narrative/ref/hub expose almost no class/ID
surface); the real JS-to-HTML dependency lives in the `*-cc.html` interactive
pages. Likely outcome: accept a handful of cross-references and skip HTML; build
the minimal extractor only if the residual is substantial and includes real typos.

### Page-category treatment principles (established this session)
- **Normal content pages** (narrative, tools, arch, ref, hub): visuals were
  emergent/loose. Default to consolidating and simplifying. Preserve a difference
  only if it carries meaning (e.g. category-tag colors). Do NOT preserve
  accidental creative-license differences.
- **Static mockup pages** (BDL guide): recreate UI; open question is reuse real CC
  component classes vs keep standalone `mock-*`. Decide after CC CSS understood.
- **Interactive mockup pages** (`*-cc.html`): STRICT visual fidelity to the real
  CC page (the real CC UI is their external spec). Highest preservation bar, most
  JS-dependent, genuinely last. Likely reuse real cc-shared.css/JS.

### Temporary-drift policy (as applied)
Temporary drift is acceptable on a first pass IF there is a tracked plan to remedy
it - never a silent permanent exception, never a mental exception list. Lower
stakes here than CC/standalone because this is documentation HTML, not a live tool
where lost functionality is unacceptable. See TEMP-DRIFT-ARCH.md.

---

## 6. Architecture / mechanics constants (docs zone)

- Tree: `public/docs/` with `pages/` (+ `cc/`, `arch/`, `ref/` subfolders),
  `data/ddl/` (doc-registry.json + per-schema JSON), `css/`, `js/`.
- `nav.js` reads `doc-registry.json` (generated from `Component_Registry` doc_*
  columns), builds nav in two passes (immediate parent nav, async child
  discovery via HEAD requests), and injects into `.doc-nav` / sticky-nav /
  section-nav containers. Filename conventions: `{pageId}.html`,
  `{pageId}-arch.html`, `{pageId}-ref.html`, `{pageId}-cc.html`,
  `{pageId}-cc-{slug}.html`.
- `ddl-loader.js` renders reference pages from per-schema JSON into `ddl-root`
  containers (`data-schema`, optional `data-category`).
- `ddl-erd.js` renders ERDs into `erd-root` containers (same data attributes).
- Component: `Documentation.Site`. Chrome prefix for the docs zone: `doc`
  (per the zone->chrome-prefix map already in the spec).
- Byte discipline: no BOM, pure ASCII (HTML entities not raw chars), CRLF,
  single trailing newline. Full-file deliverables, exact production names.

---

## 7. One-line status

CSS layer: DONE (4 files + palette consolidation). HTML: 2 of 4 page-types DONE
(narrative + architecture, ~32 pages). Remaining: the JS-led layer (reference,
ERD, cc-mockups), all gated on designing the docs-zone JS spec branch (Option C),
which leads off the next session as a spec-design task before any JS refactor.

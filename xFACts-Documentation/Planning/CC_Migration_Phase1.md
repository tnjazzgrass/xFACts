# CC Migration — Phase 1: Skeleton Refactor to Spec

*Working document. Tracks the per-page Phase 1 conversion across the Control Center. Retired or archived when Phase 1 is complete on every page.*

---

## 1. Purpose

Phase 1 is the first of multiple migration phases that bring every Control Center page from the legacy architecture (engine-events shared files, inline event handlers, DOMContentLoaded boot pattern, free-form file structure) onto the current spec (cc-shared.* anchor files, bootloader-driven page boot, structured banners and sections, contract identifiers in their required homes).

Phase 1 is **the minimal refactor that makes a page operate correctly on the new shared infrastructure**. It is intentionally narrow: every change in Phase 1 is required for the page to function under the bootloader-driven model. Everything else — chrome consolidation, dispatch-table migration of inline event handlers, comment cleanup, function-body style — is left in place and surfaces as drift in the catalog. Those drift codes are the input to subsequent phases.

Subsequent phases will be documented in their own `CC_Migration_PhaseN.md` files as their scope becomes clear. Phase 2 will address inline event handler migration to dispatch tables and the related populator/spec edits that surface. Phase 3 onward will be defined based on what the catalog tells us after Phases 1 and 2.

---

## 2. Goal

Two-part goal for every Phase 1 page conversion:

1. **The page operates correctly on the new shared files** (`cc-shared.js`, `cc-shared.css`). All existing behavior is preserved. The page can be validated live in Control Center and confirmed equivalent to its pre-conversion state.
2. **Everything that violates the current spec but isn't required for the page to function surfaces as drift in `Asset_Registry`.** The catalog after a Phase 1 conversion is the authoritative work list for that page's subsequent phases.

Phase 1 is structurally complete — banners and sections are in spec form, contract identifiers are in their required homes, the file header is in spec form, the page boots via the bootloader. It is not behaviorally complete — chrome is not consolidated, inline event handlers are not migrated, style drift is not addressed.

---

## 3. Scope rules

### 3.1 In scope (required for first pass)

A change belongs in Phase 1 if leaving it out would leave the page non-functional under the bootloader-driven model, or if the change is a zero-risk structural prerequisite for later passes.

The full first-pass checklist is in §5.

### 3.2 Out of scope (deferred to later phases)

The following are explicitly deferred to later phases:

- **Inline event handler migration.** `onclick="bch_openDetail()"` patterns stay in Phase 1. Migrating to `data-action-<event>` + dispatch table entries is behavior-affecting work that needs its own pass with live validation per interaction.
- **Chrome consolidation.** Locally-declared classes, helpers, or utilities that duplicate cc-shared.* equivalents stay in place. Removing them is cross-page work that should wait for the catalog to show the full picture across all converted pages.
- **`let` → `const`/`var` migration.** `let` declarations stay; the catalog flags them.
- **`var` → `const` in CONSTANTS sections.** If a value is wrong-keyword in a structurally-correct section, leave it; the catalog flags it as `WRONG_DECLARATION_KEYWORD`.
- **Function-body style cleanup.** Excess blank lines, stray block comments, missing purpose comments — all stay; the catalog flags them.
- **Adding lifecycle hooks the page doesn't currently use.** The spec lets pages define only the hooks they use. Don't add empty `onPageRefresh` etc. for a page that doesn't currently implement them.
- **Promoting locally-defined functions to cc-shared.js.** Even if a function looks generic, leave it local in Phase 1. Promotion is later-pass work informed by cross-page catalog queries.
- **Behavioral refactors of any kind.** Phase 1 is structural only.

### 3.3 The general principle

If a change would risk breaking the page or require interaction-by-interaction live testing to confirm correctness, it belongs in a later phase. If a change is required for the page to function under the new architecture or is zero-risk structural placement, it belongs in Phase 1.

---

## 4. Phase 1 prerequisites

Before any page enters Phase 1:

- All four populators are at parity (CSS, HTML, JS, PS) to current spec knowledge
- A full backup of the entire CC site and all scripts has been generated (handled externally per session lead)
- The Phase 1 conversion target page has been chosen
- The current catalog state for the target page has been queried and saved for comparison

---

## 5. Phase 1 checklist

Every Phase 1 conversion touches four files: the page route, the API route, the page JS file, and the page CSS file. The checklist below is organized by file. Every item is in scope; the comments column flags what later phase addresses related work.

### 5.1 Page route `.ps1` file (e.g. `BatchMonitoring.ps1`)

| # | Item | Rationale | Defers to later |
|---|---|---|---|
| 1 | File header rewritten to PS spec form: `<# .SYNOPSIS .DESCRIPTION .PARAMETER .COMPONENT .NOTES #>`, with `.NOTES` containing File Name, Location, and FILE ORGANIZATION block | Required by PS spec §2 | — |
| 2 | All section banners in spec form (76-char `=` rules and `-` separators, TYPE: NAME title, description block, Prefix line) | Required by PS spec §3 | — |
| 3 | FILE ORGANIZATION list matches body banners exactly | Required by PS spec §2.2 | — |
| 4 | `ROUTE` banner present and named `PAGE PATH` | Required by PS spec §4.4 | — |
| 5 | RBAC check via `Get-UserAccess` present at top of the route block | Required by PS spec for page-route role | — |
| 6 | Body HTML emission updated: `<body data-page="..." data-prefix="...">` attributes added; bare `<body>` removed | Required — bootloader reads these | — |
| 7 | Single `<script src="/js/cc-shared.js">` tag emitted before `</body>` via `Get-PageScriptTagHtml` helper | Required — bootloader is the entry point; old two-script-tag pattern removed | — |
| 8 | `<div id="page-error-banner" class="page-error-banner"></div>` placeholder emitted in page header area | Required — bootloader uses this to render boot failures | — |
| 9 | Any inline `onclick="..."` patterns left in place | Catalog flags as `FORBIDDEN_INLINE_EVENT_HANDLER` | Phase 2 |
| 10 | Any helper-call references that should become `cc-` prefixed `data-action`s left in place | Catalog flags via dispatch validation | Phase 2 |

### 5.2 API route `.ps1` file (e.g. `BatchMonitoring-API.ps1`)

| # | Item | Rationale | Defers to later |
|---|---|---|---|
| 1 | File header rewritten to PS spec form | Required by PS spec §2 | — |
| 2 | Section banners in spec form (76-char rules, full title, Prefix line) | Required by PS spec §3 | — |
| 3 | FILE ORGANIZATION list matches body banners | Required by PS spec §2.2 | — |
| 4 | `ROUTE` banner present and named `API ENDPOINTS` | Required by PS spec §4.4 | — |
| 5 | Every API route calls `Test-ActionEndpoint` | Required by PS spec §13 | — |
| 6 | `Invoke-Sqlcmd` calls retain `-TrustServerCertificate -ApplicationName`; SQL stays as here-strings | Required by PS spec | — |
| 7 | Existing helper functions left in place inside `FUNCTIONS` banners | Skeleton only | Phase 2+ |

### 5.3 Page JS file (e.g. `batch-monitoring.js`)

| # | Item | Rationale | Defers to later |
|---|---|---|---|
| 1 | File header rewritten to JS spec form | Required by JS spec §2 | — |
| 2 | Section banners in spec form with type, name, description, Prefix line | Required by JS spec §3 | — |
| 3 | FILE ORGANIZATION list matches body banners | Required by JS spec §2.1 | — |
| 4 | Page sections re-organized into IMPORTS / CONSTANTS / STATE / FUNCTIONS taxonomy (no INITIALIZATION) | Required by JS spec §4.1 | — |
| 5 | `<prefix>_init` function declared at top level inside FUNCTIONS section | Required — bootloader's call target | — |
| 6 | Existing `DOMContentLoaded` handler logic moved verbatim into `<prefix>_init` body; DOMContentLoaded handler itself deleted | Required — bootloader handles DOMContentLoaded centrally | — |
| 7 | `connectEngineEvents()` called from `<prefix>_init` (if the page uses engine cards) | Required — engine card connection depends on this | — |
| 8 | `ENGINE_PROCESSES` const declared in `CONSTANTS: ENGINE PROCESSES` banner with `Prefix: (none)`; shape is `{ 'Process-Name': { slug: 'slug-value' } }` matching `Orchestrator.ProcessRegistry` | Required by JS spec §7.4; contract identifier per §5.5 | — |
| 9 | Any existing page lifecycle hook functions (`onPageRefresh`, `onPageResumed`, etc.) relocated into `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner with `Prefix: (none)`; banner is the last banner in the file | Required by JS spec §8 | — |
| 10 | Empty dispatch tables (`<prefix>_clickActions = {}` etc.) declared in a FUNCTIONS banner for any events the page handles, even if currently empty | Zero-risk skeleton placement; Phase 2 fills them as inline `onclick`s migrate | Phase 2 (population) |
| 11 | Obsolete comments referencing `engine-events.js` updated or removed | Comments are misleading once the page is on cc-shared.js | — |
| 12 | Page consumes only `cc-shared.js` for shared functions; no `engine-events.js` references | Required — engine-events is being retired | — |
| 13 | Inline `onclick="..."` and per-element `addEventListener` loops left in place | Catalog flags as `FORBIDDEN_INLINE_EVENT_IN_JS` and `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP` | Phase 2 |
| 14 | `let` declarations left in place | Catalog flags as `FORBIDDEN_LET` | Phase 2+ |
| 15 | `var` declarations in spec-correct STATE sections left as `var`; `var` in CONSTANTS sections left for catalog to flag as `WRONG_DECLARATION_KEYWORD` | Skeleton only | Phase 2+ |
| 16 | Function-body style (blank lines, comment style, purpose comments) left as-is | Catalog flags as appropriate | Phase 2+ |

### 5.4 Page CSS file (e.g. `batch-monitoring.css`)

| # | Item | Rationale | Defers to later |
|---|---|---|---|
| 1 | File header rewritten to CSS spec form | Required by CSS spec §2 | — |
| 2 | Section banners in spec form with type, name, description, Prefix line | Required by CSS spec §3 | — |
| 3 | FILE ORGANIZATION list matches body banners | Required by CSS spec §2.1 | — |
| 4 | Sections re-organized into LAYOUT / CONTENT / OVERRIDES taxonomy as appropriate | Required by CSS spec §4 | — |
| 5 | Class names that already match `<prefix>-` form left as-is; class names that don't match left for catalog to flag | Skeleton only | Phase 2+ |
| 6 | Locally-redeclared classes that shadow cc-shared.css equivalents left in place | Catalog flags as drift; chrome consolidation phase addresses | Phase 3+ |
| 7 | Duplicate keyframe definitions (e.g., local `pulse`, `spin`) left in place | Catalog flags; chrome consolidation phase addresses | Phase 3+ |

---

## 6. Conversion sequence per page

A Phase 1 conversion runs in this order. Each step is fully completed before the next begins.

1. **Catalog snapshot.** Capture current `Asset_Registry` rows for the target page across all four file types. Save the row counts and drift code distribution.
2. **Backup confirmation.** Confirm the most recent backup includes the target page's four files.
3. **Refactor the four files.** Apply the §5 checklist in any order. Recommended order: CSS first (easiest, no behavior implications), then page route .ps1, then API route .ps1, then page JS.
4. **Deploy the refactored files** to the Control Center server.
5. **Restart Pode** (or whatever restart mechanism the live deployment requires).
6. **Live validation.** Open the page in Control Center. Click through every interaction the page supports. Confirm visual equivalence to pre-conversion behavior. Confirm engine cards connect and update if the page has them. Confirm no console errors.
7. **Catalog refresh.** Run all four populators (`CSS → HTML → JS → PS`).
8. **Drift review.** Compare post-conversion drift codes against pre-conversion. New drift should be exclusively the items deferred to later phases (`FORBIDDEN_INLINE_EVENT_IN_JS`, `FORBIDDEN_LET`, chrome-consolidation drift, etc.). Drift from skeleton structural items (banners, sections, file header, prefix declaration, contract identifier placement) should go to zero on the converted page.
9. **Record the outcome** in §8 below.
10. **Version bump** in `System_Metadata` for each affected component.

---

## 7. Validation criteria

A Phase 1 conversion is complete when **all** of the following are true:

- The page loads in Control Center without console errors
- The page boots via the bootloader (verifiable: `data-page` attribute present, `<prefix>_init` runs, no DOMContentLoaded handler in the page JS)
- Every interaction the page supported pre-conversion still works
- Engine cards connect to ProcessRegistry-tracked processes correctly (if the page has them)
- The page's `Asset_Registry` rows show:
  - Zero drift on file header (file_header in spec form)
  - Zero drift on banner structure (all banners in spec form)
  - Zero drift on section ordering (all sections in correct order)
  - Zero drift on contract identifier placement (`ENGINE_PROCESSES` and hooks in correct homes)
  - Zero drift on prefix declarations (every banner declares the right prefix)
  - Zero `MISSING_PAGE_INIT`
  - Zero `MISSING_ENGINE_PROCESSES_DECLARATION` or related (if applicable)
  - All remaining drift is in the categories explicitly deferred to later phases

If any of these fail, the conversion is not complete. Investigate the discrepancy. Likely sources: populator gap (file is correct but populator flagged it incorrectly), spec gap (the spec didn't account for a pattern the file uses), or a real Phase 1 step missed (re-check §5 checklist).

---

## 8. Per-page outcomes tracker

This section is populated as pages convert. Order of conversion is not yet decided; pages will be selected based on impact, complexity, and team availability at each conversion session.

| Page | Phase 1 status | Date converted | Drift count post-conversion | Notes |
|---|---|---|---|---|
| Admin | not started | — | — | High complexity; deferred to later in sequence |
| ApplicationsIntegration | not started | — | — | |
| Backup | not started | — | — | |
| BatchMonitoring | not started | — | — | ProcessRegistry pre-populated; viable pilot candidate |
| BDLImport | not started | — | — | High complexity; deferred |
| BIDATAMonitoring | not started | — | — | |
| BusinessIntelligence | not started | — | — | |
| BusinessServices | not started | — | — | |
| ClientPortal | not started | — | — | |
| ClientRelations | not started | — | — | |
| DBCCOperations | not started | — | — | |
| DmOperations | not started | — | — | |
| FileMonitoring | not started | — | — | |
| Home | not started | — | — | Minimal page; viable pilot candidate |
| IndexMaintenance | not started | — | — | |
| JBossMonitoring | not started | — | — | |
| JobFlowMonitoring | not started | — | — | |
| PlatformMonitoring | not started | — | — | High complexity; deferred |
| ReplicationMonitoring | not started | — | — | |
| ServerHealth | not started | — | — | High complexity; deferred |

`Phase 1 status` values: `not started`, `in progress`, `complete`, `blocked` (with reason in Notes).

---

## 9. Subsequent phases

Phase 1 is structural only. The catalog after a Phase 1 conversion will surface drift in several categories that subsequent phases address:

- **Phase 2 (planned):** Migrate inline event handlers to `data-action-<event>` + dispatch table entries. Populate the empty dispatch tables declared in Phase 1. Address related catalog drift (`FORBIDDEN_INLINE_EVENT_IN_JS`, `FORBIDDEN_INLINE_EVENT_HANDLER`, `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP`, `UNRESOLVED_DATA_ACTION`). Each Phase 2 conversion is per-page and requires live interaction-by-interaction validation.
- **Phase 3+ (TBD):** Chrome consolidation (remove duplicated local classes, helpers, keyframes; promote where appropriate; address `WRONG_DECLARATION_KEYWORD`, `FORBIDDEN_LET`, style drift). Scope and structure decided once Phases 1 and 2 are complete across a meaningful number of pages.

Each phase will have its own `CC_Migration_PhaseN.md` document with the same shape as this one: scope rules, checklist, conversion sequence, validation criteria, per-page tracker.

---

## 10. Cross-references

- `CC_File_Format_Initiative.md` — the umbrella initiative tracker. Phase 1 is the active operational phase under that initiative.
- `CC_Catalog_Pipeline_Working_Doc.md` — populator status, schema state, lessons learned. The catalog the Phase 1 process queries.
- `CC_CSS_Spec.md`, `CC_JS_Spec.md`, `CC_HTML_Spec.md`, `CC_PS_Spec.md` — the four specs defining what compliant files look like.
- `xFACts-Helpers.psm1` — source of `Get-PageScriptTagHtml` (consumed by every Phase 1 page route conversion).
- `cc-shared.js`, `cc-shared.css` — the new shared anchor files every Phase 1 page consumes.

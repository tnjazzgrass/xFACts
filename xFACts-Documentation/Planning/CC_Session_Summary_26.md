# CC Session Summary 26 — Business Services Page Migration + JS/HTML Populator Defect Fixes

*Session date: 2026-06-02. Continued from Session 25. This session completed the Business Services departmental page migration (all four files), resolved its post-deployment drift, and fixed two genuine populator defects surfaced by that migration — an `ENGINE_PROCESS_PAGE_MISMATCH` false positive (route derivation) and a `JS_HTML_ID_MALFORMED` false positive (attribute scanner boundary). Net result: every refactored Control Center page now sits at zero legitimate drift. The remaining unmigrated pages are all old-design and represent the next phase of work.*

---

## 1. Purpose

Session 25 left the populators proven against the partially-refactored pages. This session migrated the Business Services departmental page — the first departmental page with real orchestrated engine-card processes — and in doing so surfaced two populator false positives that no prior page had triggered, because Business Services was the first page to exercise (a) a nested route (`/departmental/business-services`) and (b) a `data-action-<prefix>-<arg>-id` argument attribute with a literal value.

Both were genuine populator defects, not file problems. Per the standing principle (investigate-and-fix, no backlog), both were fixed this session rather than deferred. Fixing them required touching all four Asset Registry populator infrastructure files.

---

## 2. What landed

### 2.1 Business Services page migration (4 files, complete and validated)

Component `DeptOps.BusinessServices`; cc_prefix `bsv`; route `/departmental/business-services`; body class `cc-section-departmental`; two engine cards (`collect`, `distribute`) bound to processes `Collect-BSReviewRequests` / `Distribute-BSReviewRequests`.

- **business-services.css** — compound modifiers corrected to all-`bsv-` form with empty standalone state-tags; dead orphan classes removed; structural hooks added; stale shared-class prose updated.
- **business-services.js** — full rewrite to the cc-shared bootloader contract: `bsv_init` boot function, `bsv_handleClick` dispatch, `bsv_ENGINE_PROCESSES` declared with `var`, four lifecycle hooks last, all shared calls via `cc_*`. Flip-card handler toggles state on the faces, not the card root (descendant combinators forbidden).
- **BusinessServices.ps1** (page route) — CBH header + CHANGELOG + ROUTE banners; transitional CCShared import shim as first scriptblock statement; `cc-` chrome shell; unified slideout + modal overlays.
- **BusinessServices-API.ps1** — CBH header + single ROUTE banner (no CHANGELOG for api-route); `Test-ActionEndpoint` guard as first statement in all 7 endpoints; all 13 SQL here-strings preserved byte-for-byte (modulo trailing-whitespace strip — see §2.2).

### 2.2 Post-deployment drift cleanup (BusinessServices page)

Six genuine drift rows resolved across the four files:

- **MALFORMED_ENGINE_CARD (×2)** — corrected the engine-card markup: bar div is exactly `cc-engine-bar` (not `cc-engine-bar cc-disabled`), countdown span is empty (not `&nbsp;`). The disabled state and countdown content are applied at runtime by cc-shared.js, invisible to the populator. Matches the Backup.ps1 precedent (Session 15 §2.6). Note: an earlier in-session recollection had this rule backwards; the spec was right.
- **MALFORMED_PAGE_SHELL_WHITESPACE** — added the required single blank line between `</title>`, the page-css `<link>`, and the cc-shared `<link>`.
- **MISSING_PANEL_PURPOSE_COMMENT (×2)** — root cause was an ID collision: inner ids `bsv-slideout-title` / `bsv-slideout-body` matched the overlay-outer-id pattern `<prefix>-slideout-<purpose>`, so the populator misclassified them as overlay constructs needing purpose comments. Renamed to `bsv-detail-slideout-title` / `bsv-detail-slideout-body` (mirrors the modal's `bsv-detail-modal-*`, which does not collide). Outer overlay id `bsv-slideout-detail` left intact; 10 JS references updated in lockstep.
- **TRAILING_WHITESPACE (API)** — stripped trailing whitespace from all 67 lines (26 inside SQL here-strings). All 13 queries confirmed functionally identical token-for-token; the spec's TRAILING_WHITESPACE rule is a flat per-file scan with no here-string exemption.

### 2.3 Populator defect fix #1 — ENGINE_PROCESS_PAGE_MISMATCH (route derivation)

**Symptom:** `business-services.js` fired `ENGINE_PROCESS_PAGE_MISMATCH` because the JS populator derived the file's page route as `/business-services` (naive `/` + basename), while ProcessRegistry correctly has the processes under `/departmental/business-services`.

**Root cause:** `Get-PageRouteForJsFile` guessed the route from the filename. JS files contain no `Add-PodeRoute`; the route lives in the sibling Route `.ps1`. The guess only works for top-level routes, not nested ones.

**Decision path (investigated, not assumed):**
- ProcessRegistry exposes no component-level page key — only `module_name` (too coarse; DeptOps spans multiple pages) and `cc_page_route`. Object_Registry has no route/path column except the physical file path. So a schema-free fix had to derive the route from the route file itself.
- `/server-health` proved the page is keyed by **route**, not component: one page route aggregates engine-card processes from multiple components (`ServerOps.ServerHealth` → dmv/xe + `ServerOps.Disk` → disk/disksummary), and `ServerOps.Disk` has no route file of its own. So the process lookup must stay route-keyed; only the route **derivation** changes.
- Verified via SQL against live data: every page JS file maps to exactly one Route object in its component (one-Route-per-component invariant holds across all 24 page JS files). The route literal is read from that Route file's `Add-PodeRoute -Path`.
- Pipeline now runs populators in **parallel** (the resolver script handles cross-file dependencies at the end), so the JS populator cannot read HTML-populator output mid-run; it must derive the route self-contained by parsing the route `.ps1`.

**Fix (3 files):**
- **xFACts-AssetRegistryFunctions.ps1** (shared, additive): added `Get-JsRouteFileMap` (js_file_name → sibling Route file path, via Object_Registry component self-join); promoted `Get-PodeRoutes`, `Get-CommandAstName`, `Get-StringValueFromExpression` verbatim from the HTML populator into the PS AST helpers section; added `Get-FirstPodeRoutePathFromFile` (ParseFile → Get-PodeRoutes → first `.Path`).
- **Populate-AssetRegistry-JS.ps1**: replaced `Get-PageRouteForJsFile` body to resolve the real route via the map + a per-run parse cache (name/signature unchanged, single call site untouched); added the map load and cache init in EXECUTION. All four ENGINE_PROCESSES checks and the route-keyed process lookup unchanged.
- **Populate-AssetRegistry-HTML.ps1**: removed the three now-duplicated local helper definitions (byte-identical to the promoted versions; six call sites now resolve to shared). `Get-PodeRoutes` was the sole occupant of the `FUNCTIONS: ROUTE DISCOVERY` section, so that empty section banner and its FILE ORGANIZATION entry were removed. `Get-AddPodeRoutePathForScriptBlock` stays local (HTML-specific; now calls the shared helpers). FILE ORG ↔ banners verified identical (28 entries each).

**Result:** the row cleared on the next run. Route extraction now lives in exactly one place, consumed by both the HTML and JS populators.

### 2.4 Populator defect fix #2 — JS_HTML_ID_MALFORMED id="0" (attribute scanner boundary)

**Symptom:** `business-services.js` line 486 (`bsv_renderGroupBadges`) fired `JS_HTML_ID_MALFORMED` on `id="0"`, where the source is `data-action-bsv-group-id="0"` (the "All" badge). This data-action argument form is spec-sanctioned (HTML spec §7.4; the spec's own example is `data-action-bsv-batch-id`).

**Root cause:** `Get-HtmlAttributeOccurrences` used `\b(class|id)\s*=...`. Because `-` is a non-word character, the word boundary matched between `group-` and `id`, so the scanner extracted `"0"` as a standalone HTML id. Any attribute name ending in `-id` (or `-class`) was mis-scanned. The HTML populator does not share this defect because it tokenizes properly via `Get-AttributesFromToken`.

**Fix (1 file):** replaced `\b` with the negative lookbehind `(?<![\w-])`, requiring `class`/`id` to be a standalone attribute name (not preceded by a word character or hyphen). Verified against six cases: the false positive disappears, the `data-action-bsv-batch-id` spec example stops mis-matching, and every legitimate `class="..."`/`id="..."` still resolves. The coarse `Test-LooksLikeHtml` heuristic (line 534) was deliberately left as `\b` — a `data-...-id=` string *is* HTML-ish, so a loose match there is correct.

**Result:** `business-services.js` dropped to zero drift on the next run.

---

## 3. Current state — zero legitimate drift on all refactored pages

Every refactored page is now clean or carries only known-transitional drift:

- **Fully clean (0 rows):** backup.css/js, Backup-API.ps1; business-services.css/js, BusinessServices-API.ps1; business-intelligence.css/js, BusinessIntelligence-API.ps1; client-relations.css/js, ClientRelations-API.ps1; replication-monitoring.css/js, ReplicationMonitoring-API.ps1; cc-shared.css/js; xFACts-AssetRegistryFunctions.ps1; Resolve-AssetRegistryReferences.ps1; Invoke-AssetRegistryPipeline.ps1.
- **Known-transitional (2 rows each on the page routes):** Backup.ps1, BusinessServices.ps1, BusinessIntelligence.ps1, ClientRelations.ps1, ReplicationMonitoring.ps1 — the `MISSING_RBAC_CHECK_PAGE` + import-in-ROUTE rows from the CCShared import shim, which clear at module cutover (when `xFACts-Helpers.psm1` is retired and `xFACts-CCShared.psm1` is startup-loaded).
- **Populator scripts themselves** (CSS/HTML/JS/PS populators at ~5-6 rows each) and **xFACts-CCShared.psm1** (37 rows) remain — tracked, not page-migration work.

The four populators are now mutually consistent with the four specs and proven against real files: when they fire, the signal is trustworthy.

---

## 4. Phase shift — from partial-refactor to full migration

This session closed out the last of the partially-refactored pages. Every remaining Control Center page is old-design top to bottom (the site-wide drift snapshot shows them at 30%–95% non-compliance — e.g. admin.css 720/748, bdl-import.css 781/811). Implications for the next phase:

- **The unit of work is now the whole page, four files at once**, with no partial-credit starting point. The four files share contracts (JS dispatch ↔ HTML data-actions ↔ CSS classes ↔ route shell), so half-migrating a page leaves contracts dangling. One complete page per session/stretch.
- **The template now exists and is trustworthy.** Backup and Business Services are full, validated four-file examples of every construct (engine cards, overlays, dispatch tables, bootloader contract, route/API split). A from-scratch rewrite is "conform this page's content to the proven shape," not "invent the shape."
- **The populators are now a regression safety net**, not a worklist. A page can be rewritten aggressively and the populator trusted to flag only real misses.
- **First populator run on an old page lights up entirely** — that is expected (whole-file pre-spec drift), not a punch-list.

---

## 5. Next session — candidates and considerations

### 5.1 Next page to migrate (primary work)

Pick a representative old-design page. Consideration: choose one that exercises constructs the five clean pages did *not*, so any latent spec/populator gap (one that only surfaces on an un-exercised construct) is found early while context and momentum are fresh — rather than on the last page. The clean set so far is monitoring-heavy plus departmental; a page with a distinct interactive surface, a different overlay pattern, or a construct none of the clean pages used is the highest-value early target. Final selection is by-ear at session start.

### 5.2 Spec / doc clarifications to consider (none are rule changes)

Three items surfaced this session that are worth a small, focused decision next session. All are clarifications or examples, not new rules — but each deserves first-principles framing rather than a rushed edit:

1. **Overlay inner-id naming constraint (HTML spec).** Inner elements inside an overlay must not take the form `<prefix>-<construct>-<purpose>` where `<construct>` is `slideout`/`modal`/`slideup`, because that collides with the overlay-outer-id pattern and triggers a confusing `MISSING_PANEL_PURPOSE_COMMENT`. We fixed Business Services by renaming, but nothing in the spec warns against it, and the natural inner-id name (`<prefix>-slideout-title`) will hit this trap on the next migration. **Decision needed:** document it as a naming convention, make it a hard `MALFORMED_ID_VALUE`-class rule, or have the populator disambiguate inner vs. outer overlay ids more gracefully (e.g. only treat an id as an overlay outer when its element also carries the matching `cc-*-overlay` class).

2. **`Test-ActionEndpoint` guard canonical form (PS spec).** The PS spec lists "API route without `Test-ActionEndpoint` call" as a rule but does not show the canonical form of the guard. The exact form — `if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }` as the first statement in each endpoint — has had to be reconstructed from memory in two consecutive sessions. **Consider** adding it as a clarifying example in the API-route section. Clarifying example, not a rule change.

3. **Pipeline doc — parallel-run + route derivation.** The populators now run in parallel with the resolver script handling cross-file dependencies at the end, and the JS populator now derives a JS file's page route by parsing its sibling Route file's `Add-PodeRoute -Path` (via `Get-JsRouteFileMap` / `Get-FirstPodeRoutePathFromFile`). These are architecture/implementation facts, not file rules, so they belong in `CC_Catalog_Pipeline_Working_Doc.md`, not the four specs. **Consider** capturing them there if not already present.

### 5.3 Performance side-note (not actionable)

The JS populator runs faster in parallel (~2.5 min) than standalone (~5 min). Likely warm shared-cache (all populators hit the same registry tables and overlapping files) and/or latency-hiding (overlapping I/O waits), possibly compounded by cross-file resolution work having moved to the resolver. Not investigated; not banked on as a durable property. Mentioned only so it is not mistaken for a code regression if it shifts.

---

## 6. Files delivered this session

- `business-services.css`, `business-services.js`, `BusinessServices.ps1`, `BusinessServices-API.ps1` (page migration + drift fixes)
- `xFACts-AssetRegistryFunctions.ps1` (shared: new route helpers, additive)
- `Populate-AssetRegistry-JS.ps1` (route resolution + id-scanner fix)
- `Populate-AssetRegistry-HTML.ps1` (helper-dedup; ROUTE DISCOVERY section removed)

All PowerShell files CRLF + pure ASCII; no live PowerShell parse was available in-session, so a syntax pass before deployment was advised for the populator edits.

---

## 7. Cross-references

- `CC_Session_Summary_25.md` — predecessor; the partially-refactored-page baseline.
- `CC_HTML_Spec.md` — §5.4 overlay constructs / §7.4 action arguments (relevant to §5.2 items 1 and the id-scanner fix).
- `CC_PS_Spec.md` — §11.1 route rules (relevant to §5.2 item 2).
- `CC_Catalog_Pipeline_Working_Doc.md` — target for §5.2 item 3.
- `xFACts_Platform_Registry.md` — Object_Registry / ProcessRegistry / Component_Registry content used to verify the route-derivation invariants.

---

*End of Session 26 summary. Next session: migrate the next (old-design) Control Center page — selection by-ear, favoring a page that exercises constructs the five clean pages did not. Optionally resolve the three §5.2 spec/doc clarifications first.*

# CC Session Summary 17 — Replication Monitoring Refactor, Vendored-Library Mechanism, Catalog Resolution Architecture

*Session date: 2026-05-28.*

---

## 1. Purpose

Seventeenth session in the CC File Format Standardization initiative, and the second full-page refactor under the four-spec regime (Backup was the first, Session 14). This session brought the **Replication Monitoring** page (`ServerOps.Replication`, prefix `rpm`, slug `replication-monitoring`, route `/replication-monitoring`) to spec compliance across all four file types, then resolved the one genuine spec gap the page surfaced — the absence of a sanctioned mechanism for vendored third-party browser libraries — end-to-end in-session: spec amendment, populator changes (HTML and JS), local file vendoring, and the route's library references migrated off CDN.

The page work is complete. In parallel, late-session diagnostic work uncovered a fundamental architectural defect in how the four populators perform cross-spec resolution. The defect predates this session and explains a previously-unrecognized pattern of `<undefined>` source_file values across the catalog. The defect is documented here as the highest-priority next-session work, ahead of any further page migration.

The four files refactored this session:

- `replication-monitoring.css`
- `replication-monitoring.js`
- `ReplicationMonitoring.ps1` (page route)
- `ReplicationMonitoring-API.ps1` (api route)

Plus amendments to two platform files in service of the vendored-library mechanism:

- `CC_HTML_Spec.md`
- `Populate-AssetRegistry-HTML.ps1`
- `Populate-AssetRegistry-JS.ps1`

And one Object_Registry insertion adding the two vendored Chart.js files as catalog-classified web assets parallel to the existing `xlsx.full.min.js` entry.

---

## 2. What was done

### 2.1 CSS — compound state-modifier refactor (`replication-monitoring.css`)

Brought every compound state/type modifier into the Backup idiom (the pattern established in `backup.css` and confirmed this session by direct reading as the house standard). Thirteen modifier tokens were converted: the six agent-card status modifiers (`rpm-status-healthy/idle/warning/critical/stopped/unknown`), the three queue-depth modifiers (`rpm-queue-healthy/warning/critical`), the three agent-type tag modifiers (`rpm-tag-logreader/push/pull`), and the shared toolbar `rpm-active` modifier.

For each modifier the refactor applied the literal-minimal prefix rename (e.g. `status-warning` → `rpm-status-warning`, keeping the descriptive tail and only adding the `rpm-` prefix) plus the assembled idiom: an empty standalone rule carrying a leading `/* purpose. */` comment, declared once, followed by the compound rule(s) that style it with a trailing `{ /* state */ }` comment. `rpm-active` is declared a single time at its first use and reused across all three compound bases (`.rpm-time-btn`, `.rpm-btn-correlation`, `.rpm-event-agent-btn`), matching how `backup.css` declares a shared modifier once.

Both `@media` blocks received a purpose comment on the nested rule (not just on the block), clearing the two `MISSING_PURPOSE_COMMENT` rows. The `rpm-badge-*` classes were left as-is: they are standalone single-class rules used space-separated on `.rpm-agent-status-badge`, not compound selectors, and were already clean.

### 2.2 JS — class-string lockstep + dispatch model (`replication-monitoring.js`)

Updated every class-string emission to match the CSS rename, in lockstep so rendered markup still matches the stylesheet: the agent-card template now emits `rpm-status-` + statusClass; the queue-depth value class resolves to the prefixed `rpm-queue-*` forms; the agent-type tag emissions use `rpm-tag-logreader/push/pull`; and all `active` class toggles (correlation button, agent-filter buttons, time-range buttons) plus the JS-emitted "All" filter button now use `rpm-active`. The `'queue-depth'` token used as a section-info lookup key was correctly left unchanged (it is not a CSS class). `node --check` passes; all top-level identifiers carry the `rpm_`/`cc_` prefix.

### 2.3 Page route — shell + vendored library relocation (`ReplicationMonitoring.ps1`)

Comment-based-help header with `CHANGELOG: CHANGE HISTORY` and `ROUTE: PAGE PATH` banners. The `<head>` was restored to the mandated `title` + two `link`s with exactly one blank line between each adjacent shell element per HTML spec §1.2.3. The two Chart.js `<script>` tags were moved out of `<head>` and into the body, immediately before the mandatory `cc-shared.js` tag, pointing at the local vendored paths `/js/chart.min.js` and `/js/chartjs-adapter-date-fns.min.js` (see §2.6). All data-action values cross-resolve to the JS dispatch tables. CRLF, ASCII, no BOM.

The transitional `Import-Module xFACts-CCShared.psm1` line remains as the first statement in the route scriptblock; see §3.1.

### 2.4 API route — endpoint structure (`ReplicationMonitoring-API.ps1`)

Comment-based-help header with a single `ROUTE: API ENDPOINTS` banner, no CHANGELOG (forbidden on api-routes). Six GET endpoints (agent-status, queue-history, latency-history, throughput-history, events, thresholds), each opening with the `Test-ActionEndpoint` guard, a blank line, then `try` — matching the Backup-API convention. Per that same convention, no per-endpoint subsection markers are used: endpoints are separated by a single blank line and identified by their `-Path`. Trailing whitespace stripped from the SQL here-strings. Query logic preserved verbatim from the original. CRLF, ASCII, no BOM.

### 2.5 State-modifier idiom — confirmed against `backup.css`

This session resolved the two CSS naming questions left open from the prior session by reading `backup.css` directly rather than reasoning in the abstract. Backup establishes both answers: (1) the literal-minimal prefix rename, and (2) one shared standalone modifier class declared once and reused across every compound base. There is a recommendation to add a clarifying subsection to `CC_CSS_Spec.md` capturing the assembled recipe (see §4).

### 2.6 Vendored-library mechanism — spec + populators + route

The page surfaced a real spec gap: the HTML spec permitted only `title` + `link` in `<head>` and exactly one body `<script>` (`/js/cc-shared.js`), with no provision for a third-party browser library. Chart.js was being loaded from a CDN in `<head>`, producing `MALFORMED_HEAD` and `WRONG_SCRIPT_SOURCE` rows, and was an external dependency unsuitable for the air-gapped server. The fix follows the existing local-vendoring precedent (the unmigrated BDL Import page vendors `xlsx.full.min.js` locally under `public/js/`).

**Decisions locked this session:**

- **Vendor locally, not CDN.** Chart.js and its date adapter are committed under `public/js/` and served locally, exactly like `xlsx.full.min.js`. Browser loads from `/js/`, so neither server nor workstation needs internet for the page to work.
- **Body slot, before `cc-shared.js`.** Vendored library tags live in `<body>`, after page content, immediately before the mandatory shared tag. `<head>` stays purely `title` + `link`.
- **Flat `/js/` placement, allow-list by filename.** Files sit in the existing flat `public/js/` directory (not a `/js/vendor/` subfolder), to avoid disrupting the local→GitHub documentation/push pipeline. The populators recognize them by a closed filename allow-list, not by path prefix.
- **`.min.js` naming for all vendored files**, matching the established `xlsx.full.min.js` convention. The three vendored files are `chart.min.js`, `chartjs-adapter-date-fns.min.js` (the self-contained adapter build with date-fns baked in), and `xlsx.full.min.js`. With all three on `.min.js`, the existing `*.min.js` walk-exclusion in the JS populator naturally keeps them out of the parse-and-walk set; the vendored allow-list cleanly drives anchor-row emission instead.

**`CC_HTML_Spec.md` amendment.** Added §3.2.2 "Vendored library references" defining the `<script src="/js/<library>"></script>` form, its body placement (before `cc-shared.js`), the no-extra-attributes rule, the local-`/js/`-only rule, and the closed vendored-library set (§3.2.2.2: `chart.min.js`, `chartjs-adapter-date-fns.min.js`, `xlsx.full.min.js`). Added a §12 forbidden-pattern row for external/misplaced/attributed vendored references, and clarified the §14 `UNEXPECTED_SCRIPT_TAG` and `WRONG_SCRIPT_SOURCE` descriptions to note the vendored-reference exemption. Adding a future library requires a spec amendment to that table.

**`Populate-AssetRegistry-HTML.ps1` amendment.** Added the `$VendoredJsFiles = @('chart.min.js','chartjs-adapter-date-fns.min.js','xlsx.full.min.js')` config constant. Two function changes consume it: `Get-PageShellDrift`'s body script-tag counter now excludes allow-listed vendored tags from the collected set before counting (so they don't trip `UNEXPECTED_SCRIPT_TAG` or the shared-src check), and `Invoke-HtmlTokenWalk`'s per-`<script>` emitter exempts allow-listed vendored srcs from `WRONG_SCRIPT_SOURCE`. Vendored tags are still emitted as `JS_FILE` USAGE rows — cataloged, not skipped — with only the false drift suppressed.

**`Populate-AssetRegistry-JS.ps1` amendment.** Added a parallel `$VendoredJsFiles` config constant with the same three entries. Discovery split into two lists: the existing `$JsFiles` walk set (authored CC JS only, retaining the `*.min.js` exclusion for anything not on the allow-list) and a new `$VendoredFiles` anchor-only list. A dedicated emission loop placed after the Pass 2 main walk (so all function definitions are in scope) iterates `$VendoredFiles`, sets `$script:CurrentFile` and `$script:CurrentFileIsShared = $true`, and calls the existing `Add-JsFileRow` to emit exactly one `JS_FILE` DEFINITION anchor row per vendored library. The vendored files are never parsed or walked: the CC JS spec does not govern third-party minified bundles, and emitting construct rows or drift against them would be noise. The anchor row exists so cross-spec USAGE references *could* resolve to a real DEFINITION — though the architectural defect described in §3.2 prevents that resolution from completing in the current pipeline.

`cc-shared.js` was deliberately not changed: the libraries load as plain body tags before it, so they are global by the time any page module runs — no bootloader mechanism required.

### 2.7 Object_Registry — vendored library entries

Two new rows inserted into `dbo.Object_Registry` classifying `chart.min.js` and `chartjs-adapter-date-fns.min.js` as `WebAsset` / `JavaScript` entries under module `Tools` (parallel to the existing `xlsx.full.min.js` entry). Descriptions are page-neutral rather than tagged to a specific consuming page, since these libraries will spread to additional pages as more charting pages migrate.

---

## 3. Remaining / gated drift

### 3.1 Transitional `Import-Module` shim — `MISPLACED_IMPORT` + `MISSING_RBAC_CHECK_PAGE`

The page route carries `Import-Module -Name '...\xFACts-CCShared.psm1' -Force -DisableNameChecking` as the first scriptblock statement, overriding the auto-loaded `xFACts-Helpers` module so `Get-NavBarHtml`/`Get-PageHeaderHtml` emit `cc-`-prefixed chrome during migration. This produces two drift codes that cannot be made conformant in a page-route: `MISPLACED_IMPORT` (the spec forbids an IMPORTS section in page-routes) and `MISSING_RBAC_CHECK_PAGE` (the shim sits before `Get-UserAccess`, which the spec requires as the first statement).

**This is expected on every migrated page, not a Replication-specific defect.** Backup carries the identical pair. Both codes clear in a single motion at platform cutover, when `Start-ControlCenter.ps1` is changed to load `xFACts-CCShared.psm1` at startup instead of `xFACts-Helpers.psm1` and the per-route `Import-Module` lines are removed. This is an interim warning to expect and ignore on each migrated page until that cutover lands.

### 3.2 Catalog cross-spec resolution architectural defect — the principal finding of this session

Late-session investigation into the vendored-library `<undefined>` source_file values uncovered a defect that predates this session's work and affects the entire catalog, not just vendored references. Documenting in full because it reframes the next-session priorities.

**The defect.** Each populator queries `Asset_Registry` at startup to preload DEFINITION rows from the *other* populators, building maps (`$jsFileMap`, `$cssClassSharedMap`, `$cssClassLocalMap`, `$htmlIdDefinitionMap`) used to resolve cross-spec USAGE references during its own walk. This preload pattern **cannot work against a truncated, mid-pipeline `Asset_Registry`**, because at the moment any populator starts, the populators that follow it have not written their DEFINITION rows yet. The standard production pipeline truncates `Asset_Registry` at the start of each run (~5–10x/day), then runs CSS → HTML → JS → PS. By the time HTML's preload queries for `JS_FILE` DEFINITION rows, the JS populator has not yet run, so the result set is empty (`JS_FILE rows loaded: 0`, observed directly in console output). Every `<script src>` USAGE row the HTML populator emits subsequently falls through to `source_file = '<undefined>'` — including for `cc-shared.js` itself, which exists as a legitimate DEFINITION row after JS later runs but cannot be retroactively resolved.

**Compounding the visibility problem: the silent-`<undefined>` design defect.** When a USAGE row's cross-spec reference fails to resolve, the populator writes the literal string `<undefined>` into `source_file` and **emits no drift code**. The project's entire validation contract is that `drift_codes` is the signal — every clean-page judgment, every acceptance gate, every "is this file done" decision queries that column. The silent `<undefined>` fall-through violates that contract: the populator knows the row failed to resolve, and records that fact in a column nothing queries. Both Backup and Replication, declared clean against zero-drift, in fact carry small numbers of `<undefined>` rows that no drift query would surface. Across the full catalog, this pattern accumulates to 1,287 `<undefined>` rows, none carrying drift.

**Decomposition of the affected rows.** A pre-`UNRESOLVED_REFERENCE` audit of the two refactored pages identified the following root causes:

- **The architectural defect itself** — affects all `<script src>` USAGE rows (and analogously CSS_FILE references) on every page once the table is truncated, because the preload returns empty. This is the single largest contributor.
- **Chrome class naming mismatch** — `cc-shared.css` defines `.cc-engine-card { ... }` but the chrome helpers (`Get-PageHeaderHtml`, etc.) emit `class="cc-card-engine"`. Markup form and CSS form are inverted. Markup form has propagated into both Backup and Replication via the chrome helpers; neither page can be fixed without aligning the source files. Account for 2 rows on Replication and 8 rows on Backup (4 engine cards × 2 mismatched classes per card).
- **CSS_VARIANT resolution scope** — classes whose only styling is under a pseudo-class form (e.g. `.bkp-detail-table-row:hover`, `.bkp-operation-table-row:hover`) are correctly cataloged by the CSS populator as `CSS_VARIANT` rows (with `variant_type='pseudo'`, `variant_qualifier_2='hover'`), not as `CSS_CLASS` DEFINITION rows. The HTML populator's `CSS_CLASS` USAGE resolution looks only at `CSS_CLASS` DEFINITION rows, not at `CSS_VARIANT` rows for the same bare class name. The class exists in the catalog; the resolver's scope just doesn't reach it. This is not a CSS populator parsing bug — the populator is deliberately emitting `CSS_VARIANT` to distinguish "variant styling decorating a class" from "the class itself is defined." The fix is a resolver design decision (extend resolver scope, or emit a companion `CSS_CLASS` row, or some third path informed by the CSS spec's intent). Pattern surfaces on `backup.js` (5 rows) but is expected to appear on any page styling classes only via interaction-state selectors.

The `cc-shared.js` `<undefined>` row that initially looked like a separate resolver bug (DEFINITION exists, lookup fails) is in fact a special case of the architectural defect: the DEFINITION row exists in the catalog at *some* time, but not at the time the HTML populator's preload runs against the truncated table.

**Why no single linear populator ordering can fix this.** The dependency between populators is bidirectional: HTML resolves `JS_FILE` USAGE against JS-populator output, and JS resolves `HTML_ID` USAGE against HTML-populator output. On a truncated single-pass run, whichever runs first has nothing to resolve against; whichever runs second can resolve against the first but not against itself. Reordering CSS → JS → HTML → PS was investigated; it shifts the failure from the JS_FILE edge to the HTML_ID edge, where the JS populator's preload-zero guard silently suppresses the `JS_HTML_ID_UNRESOLVED` drift check entirely — trading a visible failure for an invisible one. A second populator pass to converge cross-spec resolution is ruled out by runtime cost (5–10x daily, run durations too long for double-passes).

### 3.3 Smaller follow-ups that pre-date this session and are not session-17 work

- The CSS state-modifier idiom is mandated rule-by-rule but the assembled recipe is shown nowhere — first noted Session 16. Recommend a clarifying subsection in `CC_CSS_Spec.md` (e.g. §7.3) showing the full assembled skeleton.
- The slideout open/close animation mechanism on Replication (the `.cc-open` + requestAnimationFrame + transitionend pattern, derived from Backup) is undrifted but undocumented as a firm spec standard.

---

## 4. Next-session priority sequence

Both pages refactored under the four-spec regime carry `<undefined>` rows that no drift query would surface — meaning the catalog has been silently accumulating unresolved-reference debt and the project's "drift_codes is the signal" acceptance contract has been operating on incomplete data. Continuing to migrate additional pages on this baseline will compound the problem. Therefore the next session's work, in order, before any further page migration:

1. **Strip cross-populator preload-and-resolve logic from all four populators.** The pattern of querying `Asset_Registry` for other populators' DEFINITION rows during one's own run is structurally broken against a truncated pipeline and cannot be repaired by ordering. Each populator becomes single-spec: parses its own files, emits its own DEFINITION and USAGE rows, leaves cross-spec USAGE references in an unresolved/pending state (sentinel form to be picked during implementation — either a `<pending>` marker or NULL in `source_file` until the resolve phase fills it).

2. **Add a fifth pipeline script — the cross-spec resolve phase.** Runs once after all four populators complete (will be the final step of the planned Invoke wrapper, but stands as a standalone script in the interim). Iterates every USAGE row carrying an unresolved cross-spec reference, looks up the matching DEFINITION row in the now-complete catalog by `component_type` + `component_name`, sets `source_file` and `scope`. For any row where no DEFINITION exists anywhere in the catalog, stamps a new `UNRESOLVED_REFERENCE` drift code into `drift_codes` and leaves `source_file` as `<undefined>`. Pure database operations, no file parsing — fast.

3. **`UNRESOLVED_REFERENCE` drift code.** A single, universal code applied uniformly at every cross-spec resolution fall-through site. One code is sufficient across the board — the row's `component_type` and `component_name` already identify what kind of reference failed; the drift code's job is just to surface the failure in the column the project's validation contract reads. Code emitted by the resolve phase (step 2), not by the individual populators.

4. **CSS_VARIANT resolution scope.** Decide whether the resolver should extend its USAGE-to-DEFINITION lookup to consider `CSS_VARIANT` rows as valid resolution targets for `CSS_CLASS` USAGE references, or whether the CSS populator should emit a companion `CSS_CLASS` DEFINITION row whenever it emits a `CSS_VARIANT` for a class with no bare-class definition. The decision should be informed by re-reading `CC_CSS_Spec.md`'s treatment of variants and by examining how existing classes with both bare and variant rules are cataloged today (to identify the established precedent before designing the fix).

5. **Chrome class naming alignment.** Resolve the `cc-card-engine` (markup, emitted by chrome helpers) vs `cc-engine-card` (CSS, in `cc-shared.css`) mismatch. Pick which form is canonical against spec, fix the other side. Audit the chrome helpers (`Get-NavBarHtml`, `Get-PageHeaderHtml`, any other emitters) against `cc-shared.css` for additional chrome-class drift — this is best done *after* step 2 makes the drift visible, so the audit is driven by populator-surfaced facts rather than manual inspection.

6. **Re-populate, verify Backup and Replication are genuinely clean** under the corrected pipeline: zero `drift_codes`, zero `<pending>`, and `<undefined>` only where the resolve phase has explicitly stamped `UNRESOLVED_REFERENCE` against rows that genuinely have no DEFINITION anywhere. That state becomes the trustworthy baseline for further migration.

7. **Only then proceed to the next page migration.** Page to be determined.

---

## 5. What this session's deliverables do and do not depend on

The Replication page refactor and the vendored-library mechanism are **not invalidated** by the architectural defect documented in §3.2. The page itself is spec-compliant across all four file types. The vendored-library work — spec amendment, populator allow-lists in both HTML and JS, local file vendoring, route-tag relocation, Object_Registry inserts — is sound. The JS anchor rows emitted for the three vendored files are exactly what the next session's resolve phase will look up against; the design is forward-compatible with the corrected pipeline. The only thing the architectural defect changes is whether resolution *currently completes* against the truncated production pipeline — which is the next session's work to fix, not this session's.

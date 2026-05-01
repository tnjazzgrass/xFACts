# Control Center Component Registry Plan

**Created:** April 30, 2026
**Status:** v0.1 - Framework draft. Schema design and Phase 1 DDL pending dedicated session. Population work runs in parallel with CC Chrome Standardization completion.
**Owner:** Dirk
**Target File:** `xFACts-Documentation/Planning/CC_Component_Registry_Plan.md`

---

## Purpose

The xFACts platform has comprehensive cataloging coverage for the SQL/PowerShell side via `Object_Registry` and `Object_Metadata`. Together those two tables fully describe every database object and PowerShell script in the platform, allowing fast queries to answer questions like "do we already have a stored procedure that does X" or "what columns are in this table."

The Control Center side has no equivalent. Pages are made up of route .ps1 files, page CSS files, page JS files, and API .ps1 files, and the only way to answer "do we already have a CSS class for X" or "is there an API endpoint for Y" or "where is this JS function defined" is to grep through source files. The cost is real: time spent investigating, slight variations in naming creeping in (the DmOps `.active` versus `.open` slideout class is the canonical example), duplicate work when something already exists, and refactor risk when shared changes propagate to consumers no one tracked.

This plan establishes the front-end equivalent of `Object_Registry`/`Object_Metadata`: a single registry table that catalogs every component on every Control Center page (CSS classes, JS functions, JS constants, JS hooks, API routes), distinguishing local from shared, mapping consumption to definition, and serving as both **descriptive catalog** and **prescriptive naming/pattern reference**.

The intent is captured in this principle:

> **A developer building a new CC page should be able to query the catalog before writing a single line, find every existing pattern they should reuse, and add new rows for whatever they invent. By the time the page ships, the catalog is current. The catalog is the architecture; the source files are the implementation.**

---

## Part 1 - Motivation and Framing

### 1.1 The gap relative to Object_Registry/Object_Metadata

Object_Registry catalogs every SQL object (tables, views, procedures, functions) and every PowerShell script. Object_Metadata catalogs the contents of those objects (columns, parameters, dependencies). Together, two tables describe the entire SQL/PowerShell architecture in queryable form.

For the Control Center, no equivalent exists. The closest analogies:
- `RBAC_NavRegistry` knows every page exists but doesn't describe what's inside any of them
- `Object_Registry` lists CC page files (route .ps1, css, js, API .ps1) but treats them as opaque assets
- The CC Chrome Standardization Plan documents shared infrastructure in markdown but only as a side effect of the alignment work, and only narratively

The investigation cost is real and recurring. Common questions that currently require manual file inspection:

- Is there already a CSS class for a "centered modal action button"?
- Is there an API endpoint that returns the current state of all engine processes?
- Where is the `formatTimeOfDay` function defined? Is it shared?
- What pages currently use the shared `xf-modal` infrastructure?
- If I rename or refactor a shared utility, which pages are affected?
- Has anyone else solved this naming-convention question on another page?

### 1.2 Drift prevention is the highest-value outcome

The catalog is descriptive (what exists) but its *most* valuable use is prescriptive (what naming/pattern conventions to follow when building new things).

The DmOps slideout case is illustrative. DmOps's slide-panel JS toggles `.active` while every other CC page uses `.open` for the same purpose. This wasn't a deliberate divergence — DmOps was built without visibility into the convention that already existed. Now we have a backlog item to migrate it. Multiply this by every page over the lifetime of the platform and the cumulative drift is significant.

A queryable catalog flips the dynamic: when a new page is being built, "what's the convention for slideout activation classes" becomes a query, not a guess. Patterns get reused because they're discoverable.

### 1.3 Dual purpose

The registry serves two functions simultaneously:

1. **Catalog** — answers "what exists" questions across CSS, JS, API, and HTML naming conventions. Queryable. Comprehensive.
2. **Pattern enforcement** — surfaces existing naming conventions and shared utilities so new development follows them. Reduces drift.

These aren't separate concerns; they're the same data viewed differently. The catalog *is* the pattern reference because the data shows what conventions are established.

### 1.4 Coverage scope

In scope:
- Every CSS class defined or consumed by a CC page
- Every JS function, constant, and hook defined or consumed by a CC page
- Every API route handled by a CC page's API .ps1 file
- Every notable HTML element ID convention (e.g., `<purpose>-slideout-overlay`, `connection-banner`)
- Shared infrastructure components in `engine-events.css`, `engine-events.js`, and shared route helpers

Out of scope (deferred):
- PowerShell script-level component cataloging (collectors, orchestrators, helpers). The same problem exists — when working on a collector script, "is this function defined here or in a helper module" is currently unanswerable without grep. The architectural pattern proposed here is likely identical to what would solve the PS side, but designing for both at once would over-engineer the solution before the model is validated. Section 4.5 captures this as deferred.
- Markdown documentation tracking
- Database object cataloging (already covered by Object_Registry/Object_Metadata)

---

## Part 2 - Schema Design

### 2.1 The single-table model

After design discussion, the registry will be a single table — not a registry-plus-dependency-table split. The model: every page-perspective row stands on its own. A shared component used on multiple pages will have multiple rows in the registry, one per page that consumes it. That's not data duplication in the problematic sense; it's a deliberate choice that lets a single query return the complete picture for any page.

The trade-off:
- **Pro:** Single-query page profiles. `SELECT * FROM CC_Component_Registry WHERE page_component_key = 'BIDATA_Monitoring'` returns everything BIDATA needs, local or shared, no JOIN.
- **Pro:** Promotion of a local utility to shared is a clean batch UPDATE (rows get `scope = 'SHARED'`, `source_file = 'engine-events.js'`); no row insert/delete dance.
- **Pro:** Parser logic stays simple — emit one row per page-file scan that finds a reference, regardless of whether the reference is to local or shared content.
- **Con:** Shared components have multiple rows. If `xf-modal` is consumed by 15 pages, there are 15+ rows for it. Disk cost is irrelevant; cognitive cost is "remember to filter by `scope` and `page_component_key` appropriately."

A separate dependency table was considered and rejected. It would have meant two-table queries for almost every common question, with no offsetting benefit.

### 2.2 Proposed schema

The table tentatively named `CC_Component_Registry`. Final schema location (which database schema to put it in) is a Phase 0 decision item — the value depends on existing CC table conventions to confirm.

```sql
CREATE TABLE [<schema>].[CC_Component_Registry] (
    component_id              INT IDENTITY(1,1) NOT NULL PRIMARY KEY,

    -- Identity from the page's perspective
    page_component_key        VARCHAR(50)   NULL,
        -- FK to RBAC_NavRegistry.page_component_key
        -- NULL only for shared definitions with no specific page consumer

    -- The thing being cataloged
    component_type            VARCHAR(20)   NOT NULL,
        -- CSS_CLASS, CSS_VARIABLE, JS_FUNCTION, JS_CONSTANT, JS_HOOK,
        -- API_ROUTE, HTML_ID_PATTERN
    component_name            VARCHAR(200)  NOT NULL,
        -- e.g. 'xf-modal', 'escapeHtml', 'MONTH_NAMES',
        --      '/api/bidata/todays-build', 'build-slideout-overlay'
    scope                     VARCHAR(20)   NOT NULL,
        -- SHARED, LOCAL

    -- Where it lives
    host_file                 VARCHAR(200)  NOT NULL,
        -- The page-perspective file: 'bidata-monitoring.css',
        -- 'BIDATAMonitoring.ps1', 'BIDATAMonitoring-API.ps1', etc.
    source_file               VARCHAR(200)  NOT NULL,
        -- Where actually defined. Same as host_file when LOCAL;
        -- 'engine-events.css' / 'engine-events.js' / shared helper file when SHARED.
    source_section            VARCHAR(100)  NULL,
        -- Section header from the source file:
        -- 'CONTENT: SLIDEOUT PANELS', 'PAGE-SPECIFIC UTILITIES', 'API CALLS', etc.

    -- Description
    purpose_description       VARCHAR(500)  NULL,
    signature                 VARCHAR(500)  NULL,
        -- Function: '(val) -> string'
        -- CSS: 'div.xf-modal' (the rule selector)
        -- API: 'GET /api/bidata/todays-build -> { builds, total_expected_steps, ... }'
    default_value             VARCHAR(100)  NULL,
        -- '550px' for width-tier classes; '30' for refresh interval defaults
    variants                  VARCHAR(500)  NULL,
        -- JSON-ish: '{"wide": 800, "xwide": 950}' for tier classes
    usage_count               INT           NULL,
        -- How many references in this page's files (NULL for shared
        -- definition rows that don't represent a page consumer)

    -- Lifecycle / promotion
    related_component_id      INT           NULL,
        -- Self-referencing FK. If LOCAL and a SHARED equivalent exists,
        -- points at the canonical one.
    promotion_status          VARCHAR(20)   NOT NULL DEFAULT 'N/A',
        -- N/A, KEEP_LOCAL, PROMOTE_PENDING, PROMOTED
    keep_local_rationale      VARCHAR(1000) NULL,
        -- Why this stays local even though it could conceivably be shared
    design_notes              VARCHAR(1000) NULL,
        -- Naming pattern guidance, gotchas, cross-references to other rows

    -- Metadata
    first_added_dt            DATE          NOT NULL DEFAULT CAST(GETDATE() AS DATE),
    last_seen_dt              DATE          NOT NULL DEFAULT CAST(GETDATE() AS DATE),
        -- Last time the parser confirmed this component still exists
    is_active                 BIT           NOT NULL DEFAULT 1,
        -- Soft delete; goes to 0 if parser stops finding the component
    notes                     VARCHAR(1000) NULL,

    CONSTRAINT FK_CC_Component_Registry_Related
        FOREIGN KEY (related_component_id)
        REFERENCES [<schema>].[CC_Component_Registry] (component_id)
);
```

Indexes will be added based on actual query patterns. Initial proposal (subject to review):

- `(page_component_key, component_type)` — page profile queries
- `(component_type, component_name)` — "do we already have X" lookups
- `(component_name, scope)` — promotion candidate analysis
- `(scope, component_type)` — shared inventory queries

### 2.3 Component types reference

| Type | What it represents | Examples |
|---|---|---|
| `CSS_CLASS` | A CSS class selector | `xf-modal`, `slide-panel.wide`, `engine-card`, `header-bar` |
| `CSS_VARIABLE` | A CSS custom property | `--theme-blue` (none currently used; reserved for future) |
| `JS_FUNCTION` | A JavaScript function | `escapeHtml`, `formatTimeOfDay`, `loadLiveActivity`, `pageRefresh` |
| `JS_CONSTANT` | A JavaScript constant or top-level state variable | `MONTH_NAMES`, `DAY_NAMES`, `ENGINE_PROCESSES`, `PAGE_REFRESH_INTERVAL` |
| `JS_HOOK` | A hook function the page defines for the shared module to call | `onPageRefresh`, `onPageResumed`, `onSessionExpired`, `onEngineProcessCompleted` |
| `API_ROUTE` | A Pode route handler defined in an API .ps1 file | `/api/bidata/todays-build`, `/api/batch-monitoring/active-batches` |
| `HTML_ID_PATTERN` | A notable HTML element ID convention | `connection-banner`, `build-slideout-overlay`, `last-update` |

### 2.4 Example rows

A few worked examples to make the model concrete.

**Shared CSS class consumed by BIDATA:**

```
component_id              42
page_component_key        BIDATA_Monitoring
component_type            CSS_CLASS
component_name            slide-panel
scope                     SHARED
host_file                 bidata-monitoring.css
source_file               engine-events.css
source_section            CONTENT: SLIDEOUT PANELS
purpose_description       Right-edge slideout panel container with three width tiers
signature                 div.slide-panel
default_value             550px
variants                  {"wide": 800, "xwide": 950}
usage_count               1
related_component_id      NULL
promotion_status          N/A
design_notes              Use .open class on overlay AND panel to show. ID convention: <purpose>-slideout-overlay
```

**Same shared CSS class consumed by BatchMon:**

```
component_id              43
page_component_key        Batch_Monitoring
component_type            CSS_CLASS
component_name            slide-panel
scope                     SHARED
host_file                 batch-monitoring.css
source_file               engine-events.css
source_section            CONTENT: SLIDEOUT PANELS
purpose_description       Right-edge slideout panel container with three width tiers
signature                 div.slide-panel.xwide
default_value             550px
variants                  {"wide": 800, "xwide": 950}
usage_count               1
related_component_id      NULL
promotion_status          N/A
design_notes              BatchMon uses .xwide variant. Use .open class on overlay AND panel.
```

**Page-local JS function kept local with rationale:**

```
component_id              101
page_component_key        Batch_Monitoring
component_type            JS_FUNCTION
component_name            formatDurationMinutes
scope                     LOCAL
host_file                 batch-monitoring.js
source_file               batch-monitoring.js
source_section            PAGE-SPECIFIC UTILITIES
purpose_description       Formats minute count as Xm/Xh Xm/Xd Xh
signature                 (minutes) -> string
related_component_id      NULL
promotion_status          KEEP_LOCAL
keep_local_rationale      Companion to BIDATA formatDuration which takes seconds and outputs H:MM:SS. Two formatters intentional. Step 9 final pass to review naming convention.
design_notes              See related: BIDATA formatDuration (component_id 87)
```

**API route:**

```
component_id              215
page_component_key        BIDATA_Monitoring
component_type            API_ROUTE
component_name            /api/bidata/todays-build
scope                     LOCAL
host_file                 BIDATAMonitoring-API.ps1
source_file               BIDATAMonitoring-API.ps1
source_section            -
purpose_description       Returns today's BIDATA build status, step counts, and average durations
signature                 GET /api/bidata/todays-build -> { builds, total_expected_steps, avg_duration_seconds }
notes                     Used by loadLiveActivity in bidata-monitoring.js
```

### 2.5 Key query patterns

The schema is designed around these queries.

**"What's in BIDATA?"**
```sql
SELECT component_type, scope, component_name, source_file, purpose_description
FROM CC_Component_Registry
WHERE page_component_key = 'BIDATA_Monitoring'
  AND is_active = 1
ORDER BY component_type, scope, component_name;
```

**"Is there an /api/bidata/* endpoint already?"**
```sql
SELECT component_name, host_file, purpose_description
FROM CC_Component_Registry
WHERE component_type = 'API_ROUTE'
  AND component_name LIKE '/api/bidata/%'
  AND is_active = 1;
```

**"Is there a shared CSS class for modals?"**
```sql
SELECT DISTINCT component_name, default_value, variants, purpose_description
FROM CC_Component_Registry
WHERE component_type = 'CSS_CLASS'
  AND scope = 'SHARED'
  AND component_name LIKE '%modal%'
  AND is_active = 1;
```

**"Which pages reference shared escapeHtml, and how heavily?"**
```sql
SELECT page_component_key, host_file, usage_count
FROM CC_Component_Registry
WHERE component_name = 'escapeHtml'
  AND scope = 'SHARED'
  AND page_component_key IS NOT NULL
  AND is_active = 1
ORDER BY usage_count DESC;
```

**"Promotion candidates — same-named local utilities across multiple pages."**
```sql
SELECT component_type, component_name, COUNT(DISTINCT page_component_key) AS page_count,
       STRING_AGG(page_component_key, ', ') AS pages
FROM CC_Component_Registry
WHERE scope = 'LOCAL'
  AND component_type IN ('JS_FUNCTION', 'CSS_CLASS')
  AND is_active = 1
GROUP BY component_type, component_name
HAVING COUNT(DISTINCT page_component_key) > 1
ORDER BY page_count DESC, component_name;
```

**"Refactor impact — what's affected if I rename shared `formatTimeOfDay`?"**
```sql
SELECT page_component_key, host_file, usage_count
FROM CC_Component_Registry
WHERE component_name = 'formatTimeOfDay'
  AND scope = 'SHARED'
  AND page_component_key IS NOT NULL
  AND is_active = 1;
```

**"Kept-local audit — every component flagged KEEP_LOCAL with rationale."**
```sql
SELECT page_component_key, component_type, component_name, keep_local_rationale
FROM CC_Component_Registry
WHERE promotion_status = 'KEEP_LOCAL'
  AND is_active = 1
ORDER BY page_component_key, component_type, component_name;
```

---

## Part 3 - Population and Maintenance

### 3.1 Two phases of population

**Manual phase** — for the initial population of completed pages and shared infrastructure. The four pages already migrated through CC Chrome Standardization (Backup, JBoss, BIDATA, BatchMon) are well-understood and can be cataloged manually. This validates the schema, surfaces any column gaps, and proves the model end-to-end before parser investment.

**Parser phase** — once the model is validated, build a parser that reads source files (CSS, JS, route .ps1, API .ps1) and emits registry rows. The parser handles the bulk descriptive fields (component_name, component_type, host_file, source_file, source_section, signature, usage_count). Manual maintenance is required only for the intent fields (purpose_description, design_notes, keep_local_rationale, promotion_status, related_component_id).

### 3.2 What the parser would do

The parser is a Phase 3 deliverable. Sketching the approach for design discussion:

- **CSS files:** Parse class selectors (`.foo`, `.foo.bar`, `.foo .bar`). For each class, emit a row with `component_type = 'CSS_CLASS'` and `signature = <full selector>`. Source section detected from `/* ============= SECTION HEADER ============= */` comments preceding rules.
- **JS files:** Parse top-level `function X(...)`, `var X = ...`, and `function X() { ... }` declarations. Distinguish constants (uppercase names) from functions. Detect hook patterns (`onPageRefresh`, etc.).
- **Route .ps1 files:** Parse for inline HTML class references and JS callsite patterns to populate page-perspective rows that reference shared components.
- **API .ps1 files:** Parse `Add-PodeRoute -Path 'X'` invocations. For each, emit a row with `component_type = 'API_ROUTE'`.

The parser populates `last_seen_dt` on every row it reconfirms. Rows whose `last_seen_dt` falls behind a threshold (e.g., parser hasn't seen them in 7 days) get `is_active = 0`, indicating the component was probably renamed, deleted, or refactored.

### 3.3 Parser triggers — open question

The parser could run:

- **On deploy** — integrate into the deploy workflow so the catalog updates whenever files are pushed to FA-SQLDBB
- **On schedule** — daily/hourly via the orchestrator
- **On demand** — manual invocation from the Admin UI or PowerShell

Realistically, on-deploy is the most reliable trigger. The deploy is when files actually change; running the parser then guarantees the catalog stays current. This is a Phase 3 design discussion item.

### 3.4 Manual maintenance discipline

For the fields the parser doesn't handle (intent fields), the discipline is similar to Object_Metadata maintenance: when a new component is added during a CC Chrome page pass, the corresponding registry rows get their intent fields filled in as part of the same session. The plan doc for CC Chrome Standardization (Section 3.x per-page sub-sections) already captures this data narratively; the registry just structures it.

---

## Part 4 - Phasing and Execution Plan

### Phase 0 — Schema design session **[PENDING — NEXT SESSION]**

Dedicated session to:
- Confirm schema location (which DB schema does this live in — `ControlCenter`, `dbo`, or other; depends on existing CC table conventions)
- Review and refine the proposed DDL
- Identify any additional columns surfaced by walking through the four already-migrated pages
- Decide on initial index set
- Decide whether to register the table itself in `Object_Registry` (very likely yes)
- Decide whether to register the table's columns in `Object_Metadata` (matches existing pattern)

Output: Final DDL, deployed to xFACts database.

### Phase 1 — Backfill the four completed pages **[PARALLEL TO CC CHROME STEP 4]**

Manually populate registry rows for:
- Shared infrastructure (`engine-events.css`, `engine-events.js`, shared route helpers) — every shared component gets a definition row with `page_component_key = NULL`
- Backup — every component on the page (local + page-perspective rows for shared consumed)
- JBoss — same
- BIDATA — same
- BatchMon — same

Estimated row counts: ~50 shared definition rows + 4 pages × ~150 rows per page = ~650 rows. Doable in one focused session per page (or batched if scope allows).

This phase doubles as schema validation. If a page's contents reveal a gap in the schema, we evolve the schema before completing the backfill.

### Phase 2 — Catalog continues alongside CC Chrome page passes **[PARALLEL]**

For every CC Chrome page completed during Step 4 of the chrome plan, the page's registry rows get added in the same session. The pattern becomes:

1. Complete chrome alignment for page X (route + CSS + JS deploys)
2. Add registry rows for page X (manual entry from the kept-local audit and shared dependencies surfaced during the chrome work)
3. Update both plan docs

The chrome plan's Section 3.x per-page sub-sections already capture the descriptive content needed; the registry structures it.

### Phase 3 — Parser design and implementation **[FUTURE]**

After enough manual population to validate the schema and demonstrate value (probably after ~6-8 pages cataloged manually), evaluate parser feasibility. Decide:
- Implementation language (PowerShell most likely — fits existing platform tooling)
- Trigger mechanism (on-deploy preferred)
- Diff strategy — when re-parsing, how to reconcile new/changed/missing components against existing rows
- How to handle the intent fields the parser doesn't touch (must preserve them across re-parses)

### Phase 4 — Generated documentation **[FUTURE]**

Once the registry is populated and current, generate documentation pages from it. Pattern follows `Platform_Registry`'s auto-generated tables: a SQL query builds the markdown, which gets pushed to GitHub and rendered in the docs site.

Specific generated views to consider:
- "CC Shared Infrastructure" — every shared component, grouped by file and section, with descriptions
- "Per-page Component Inventory" — one section per CC page, listing local + shared components
- "Naming Conventions" — patterns derived from the data (e.g., "open*/close* function pairs")
- "API Endpoint Reference" — every CC API endpoint with signature

### Phase 5 — PowerShell script catalog **[DEFERRED]**

The same architectural pattern applies to PowerShell scripts. A collector script's "what functions are defined here vs imported from a helper module" question is the same shape as the CC "what's local vs shared" question. The schema designed here is likely directly reusable, possibly with a `component_domain` column added to distinguish CC components from PS components.

This is deferred until the CC catalog is built and validated. Designing for both at once would over-engineer before the model is proven. Once the CC version is in production and the parser is mature, evaluating extension to PS scripts becomes a Phase 5 effort with concrete lessons to draw on.

---

## Part 5 - Open Design Questions

Items to resolve in Phase 0 (next session) before generating DDL.

**Q1: Schema location.** Which database schema does `CC_Component_Registry` live in? Candidates: `ControlCenter` (if it exists), `dbo` (default), or another existing CC-specific schema. Need to confirm the convention from existing CC tables (e.g., where `RBAC_NavRegistry` lives).

**Q2: Object_Registry self-registration.** Should this table be registered in `Object_Registry` and its columns in `Object_Metadata`? Strong yes — matches existing platform pattern. Confirm during Phase 0.

**Q3: HTML_ID_PATTERN scope.** How aggressively do we catalog HTML IDs? Options:
- Every ID on every page (parser-friendly but high noise)
- Only IDs that follow a recognized pattern (e.g., `*-slideout-overlay`, `*-modal`)
- Only IDs explicitly flagged as conventions
Likely answer: middle ground — patterns get rows, one-off IDs don't.

**Q4: usage_count granularity.** Current proposal counts references within a single page's files (route + CSS + JS). Should it also distinguish where in the page the reference appears (route vs CSS vs JS)? Could be a JSON-shaped column or three separate count columns. Decide based on whether the distinction adds query value.

**Q5: Variants column format.** Currently proposed as JSON-ish text. SQL Server has `JSON` support via `OPENJSON` etc., but the data is small. Plain VARCHAR with a documented format works fine. Confirm.

**Q6: Soft-delete vs hard-delete.** Current proposal uses `is_active` as soft delete. Alternative: actually delete rows that the parser stops finding. Soft delete preserves history; hard delete keeps the table tighter. Likely answer: soft delete with a periodic archive job that hard-deletes rows with `is_active = 0` older than (e.g.) 90 days.

**Q7: Versioning on shared components.** Should shared component definitions track when they were added/changed? Current proposal has `first_added_dt` but no version history. If we want history, that's a separate audit table or a versioning column. Likely answer: defer; if it becomes valuable, add later.

---

## Part 6 - Relationship to Other Plan Documents

This plan runs in parallel with the CC Chrome Standardization Plan. Coordination points:

- **CC Chrome Standardization Plan, Section 3.x (per-page sub-sections):** the descriptive content captured narratively becomes the source for registry rows. As Section 3.x grows during Step 4 page passes, registry rows get added in the same sessions.
- **CC Chrome Standardization Plan, Step 9 (Final pass review):** the registry's "promotion candidates" and "kept-local audit" queries directly support this step. By the time Step 9 starts, the registry should be the primary tool for identifying what to promote in the final pass.
- **CC Chrome Standardization Plan, Part 8 backlog item ("Shared component registry"):** the placeholder there points at this plan. When this plan is approved and Phase 0 schema work is complete, the backlog item gets updated to reference the actual implementation status.
- **`xFACts_Development_Guidelines.md` Section 5.12:** once the registry is populated and queryable, the guidelines update to instruct developers building new CC pages to query the registry first for naming conventions and existing utilities.

---

## Revision History

| Version | Date | Description |
|---|---|---|
| 0.1 | 2026-04-30 | Initial framework draft. Schema proposed (single-table model with API routes included), motivation captured, phasing scoped to run in parallel with CC Chrome Standardization completion. Phase 0 (schema design session) and Phase 1 (backfill of four completed pages) identified as next steps. PowerShell script cataloging acknowledged and deferred to Phase 5. |

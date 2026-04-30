# RBAC Enforcement & Dynamic Nav Working Document

**Created:** April 29, 2026
**Status:** Active — Phase 3d complete; minor follow-ups + doc-page RBAC integration outstanding
**Owner:** Dirk

---

## Purpose

This document tracks the progressive rollout of RBAC enforcement, audit log cleanup, and dynamic navigation infrastructure for the Control Center. It exists to ensure consistency across multiple work sessions and to document architectural decisions made along the way.

**Use this document at session start** to understand current state and pick up the next item.

---

## What's Done

### Phase 0 — RBAC Enforcement Flip (Complete 2026-04-29)

**Goal:** Move from `audit` mode (logging WOULD_DENY events) to `enforce` mode (actually denying access) without breaking active users.

**Investigation conducted:** Analyzed 28 WOULD_DENY events across 6 users from the audit log spanning Feb 16 – Apr 21, 2026. All were page-level ACCESS_AUDIT events. Three patterns identified:
- **PowerUser hitting departmental pages** — 13 jregister hits, 1 dhirt hit. Should have access (Apps/Int team). Permission gap to fix.
- **ReadOnly+DeptManager hitting other departments** — alatsch, avragland, bgilbert. Correctly denied (departmental privacy). No action.
- **StandardUser hitting departmental pages** — dtraxler. Correctly denied. No action.

**Permission gaps patched (deployed before flip):**

```sql
-- 6 INSERTs: PowerUser + StandardUser get 'operate' on three departmental pages
INSERT INTO dbo.RBAC_PermissionMapping (role_id, page_route, permission_tier) VALUES
    (2, '/departmental/business-intelligence', 'operate'),  -- PowerUser
    (3, '/departmental/business-intelligence', 'operate'),  -- StandardUser
    (2, '/departmental/business-services',     'operate'),
    (3, '/departmental/business-services',     'operate'),
    (2, '/departmental/client-relations',      'operate'),
    (3, '/departmental/client-relations',      'operate');

-- 1 DELETE: Hard-deleted accidental ReadOnly grant on /departmental/applications-integration
-- 1 UPDATE: Fixed malformed page_route in RBAC_DepartmentRegistry for finance-accounting
```

**Audit log archived to Legacy:**
- `Legacy.RBAC_AuditLog_Archive_PreEnforcement` created with all rows from `dbo.RBAC_AuditLog`
- `dbo.RBAC_AuditLog` truncated for clean post-flip slate
- Login history (LOGIN_SUCCESS/FAILURE events) was preserved in archive

**Enforcement flipped:**
- `GlobalConfig: ControlCenter.RBAC.rbac_enforcement_mode` → `enforce`
- CC restarted to refresh cache
- Dirk verified login worked, admin gear visible, page access functional

### Phase 0.5 — Dead Config Cleanup (Complete 2026-04-29)

**`mapping_id 13` investigation and removal:**
- The `XCC-PowerUser` AD group had two RoleMapping entries: `mapping_id 2` (platform-wide, NULL scope) and `mapping_id 13` (scoped to `applications-integration`)
- Investigation traced through `Get-UserPageTier` logic: the `department_scope` check only restricts wildcard `*` permissions, and PowerUser has explicit page rows for everything — so the scope was being ignored
- Reviewed `ApplicationsIntegration.ps1` (uses `$access.Tier` and `$ctx.IsAdmin` only) and `applications-integration.js` (no scope info passed from server)
- Reviewed `Home.ps1` (uses `DepartmentScopes` only for dept-only redirect, which doesn't apply to PowerUser since they have platform access)
- **Verdict: completely dead config. Hard deleted.**

**`/dm-monitoring` reference cleanup:**
- Old route name from before March 18 rename to `/jboss-monitoring`
- Filesystem-side: confirmed `JBossMonitoring.ps1`, `jboss-monitoring.js`, and `ApplicationsIntegration.ps1` nav are clean
- Database-side: comprehensive search across `Object_Metadata`, `Object_Registry`, `Component_Registry`, all `RBAC_*` tables, `GlobalConfig`, `ProcessRegistry`, `System_Metadata`, `ActionAuditLog`, and previously `RBAC_AuditLog` (which was the only place with stale references — cleared by the truncate)
- **All clean.** Rename was thorough; only audit log had references and they're now archived.

### Phase 1 — NavRegistry/NavSection Schema (Complete 2026-04-29)

**Goal:** Establish the data foundation for dynamic navigation. No code changes — just data infrastructure.

**Two new tables under Engine.RBAC component:**

#### `dbo.RBAC_NavSection` (4 rows)

Section groupings for the dynamic Control Center navigation. Each row represents a top-level grouping with display ordering and CSS accent class.

| Column | Type | Purpose |
|---|---|---|
| `section_id` | INT IDENTITY PK | |
| `section_key` | VARCHAR(50) UNIQUE | Machine identifier — `platform`, `departmental`, `tools`, `admin` |
| `section_label` | VARCHAR(100) | Display text — `Platform`, `Departmental Pages`, etc. |
| `section_sort_order` | INT | Increments of 10 |
| `accent_class` | VARCHAR(50) NULL | CSS class for section-level styling |
| `is_active` | BIT default 1 | Soft delete |
| `created_dttm`, `created_by` | standard audit | |

**Initial rows:**

| section_key | section_label | sort_order | accent_class |
|---|---|---|---|
| platform | Platform | 10 | nav-section-platform |
| departmental | Departmental Pages | 20 | nav-section-departmental |
| tools | Tools | 30 | nav-section-tools |
| admin | Administration | 99 | nav-section-admin |

**Note on naming:** Originally proposed `monitoring` but renamed to `platform` because the section includes both monitoring pages AND operations pages (Index Maintenance, DBCC Operations, DM Operations).

#### `dbo.RBAC_NavRegistry` (20 rows)

Master inventory of CC pages with navigation metadata.

| Column | Type | Purpose |
|---|---|---|
| `nav_id` | INT IDENTITY PK | |
| `page_route` | VARCHAR(200) UNIQUE | Joins to `RBAC_PermissionMapping.page_route` |
| `nav_label` | VARCHAR(100) | Short label for nav bar |
| `display_title` | VARCHAR(150) | Page H1 / home tile heading |
| `description` | VARCHAR(500) NULL | Page subtitle / home tile description |
| `section_key` | VARCHAR(50) FK | References RBAC_NavSection |
| `sort_order` | INT | Increments of 10 within section |
| `doc_page_id` | VARCHAR(50) NULL | Doc slug; URL built as `/docs/pages/{doc_page_id}.html`. Slug **may include slashes** for subfolder paths (e.g., `cc/controlcenter-cc-platform`, `guides/bdl-import-guide`). |
| `show_in_nav` | BIT default 1 | Appears in horizontal nav bar |
| `show_on_home` | BIT default 1 | Appears as Home page tile |
| `is_active` | BIT default 1 | Soft delete |
| `created_dttm`, `created_by`, `modified_dttm`, `modified_by` | standard audit | |

**20 initial rows seeded** covering all current CC pages. Important conventions:
- `/` (Home) intentionally NOT in registry — handled as universal first link in `Get-NavBarHtml` helper
- `/admin` and `/platform-monitoring` in registry but `show_in_nav = 0` and `show_on_home = 0` — gear-icon-only access
- `/bdl-import` in registry but `show_in_nav = 0` and `show_on_home = 0` — tile-only access from Apps/Int and BI pages
- `/departmental/finance-accounting` in registry but `is_active = 0` — placeholder until department page is built
- All descriptions populated by Dirk as a follow-up pass

**Object_Metadata enrichment included:**
- Description, module, category baselines for both tables
- Column descriptions for all 8 + 15 columns
- Design notes (2 + 5 entries)
- Relationship notes (1 + 2 entries)
- Operational queries (3 entries on NavRegistry, including the gap-check)

**Object_Registry entries** added under Engine.RBAC component for both tables.

### Phase 2 — Cache + Helper Functions (Complete 2026-04-29)

**Goal:** Add the helper functions that will consume NavRegistry/NavSection data. No route changes yet.

**Changes to `xFACts-Helpers.psm1`:**

1. **`$script:RBACCache` extended** with two new keys: `NavSections`, `NavRegistry`. Cached on the same 5-minute refresh cycle as other RBAC data.

2. **`Initialize-RBACCache`** updated to load both new tables on cache refresh.

3. **`Get-UserContext` cleanup** — removed the obsolete `AccessiblePages` array (was hardcoded with stale page list, was unused). Now returns just user identity + role context.

4. **New function `Get-NavBarHtml`** — takes `UserContext` and `CurrentPageRoute`, returns a complete `<nav>` HTML block. Behaviors:
   - Home as universal first link
   - Iterates sections in `section_sort_order`, skips `admin` section entirely
   - Filters pages where `show_in_nav = 1` AND user has at least 'view' tier (via `Get-UserPageTier`)
   - Section separators between non-empty sections only
   - Applies `accent_class` to each link
   - Applies `active` class to link matching current page
   - Appends admin gear if `$UserContext.IsAdmin`
   - Defensive fallback: minimal `<nav>` if cache unloaded

5. **New function `Get-HomePageSections`** — takes `UserContext`, returns structured array of sections with their accessible pages. Same filtering as nav (but uses `show_on_home` instead of `show_in_nav`). Empty sections omitted entirely.

6. **`Export-ModuleMember`** updated to include both new function names.

**Important: nav rendering does NOT trigger audit log entries.** Only `Get-UserAccess` writes to `RBAC_AuditLog`, and that's still called per-page-entry as before. The nav helper uses `Get-UserPageTier` which is silent. Audit log volume is unchanged.

### Phase 3a/b/c — CSS + Home + JBoss Conversion (Complete 2026-04-29)

**Goal:** Validate the helper works end-to-end with one route conversion before bulk rollout.

**Files updated:**

1. **`engine-events.css`** — appended nav-bar base styles + section accent classes. The CSS for `.nav-bar`, `.nav-link`, `.nav-link.active`, `.nav-spacer`, `.nav-admin`, `.nav-separator` now lives here as the consolidated source. Added section-specific accent classes:
   - `.nav-link.nav-section-platform.active` → teal (matches existing default)
   - `.nav-link.nav-section-departmental:hover` and `.active` → yellow `#dcdcaa`
   - `.nav-link.nav-section-tools:hover` and `.active` → soft blue `#9cdcfe`
   - `.nav-link.nav-section-admin` → `display: none` defensive rule

2. **`Home.ps1`** — major restructure. Hardcoded section/tile HTML replaced with `foreach` loop over `Get-HomePageSections`. CSS updated to define `.nav-card.nav-section-departmental` and `.nav-card.nav-section-tools` instead of the old `.dept-card` class. Dept-only redirect logic preserved.

3. **`JBossMonitoring.ps1`** — minor change. Hardcoded `<nav>` block (~16 lines) and admin-gear append logic replaced with single `Get-NavBarHtml` call. All page content unchanged.

**Verified:**
- Three section headers appear on Home (Platform, Departmental Pages, Tools)
- Section colors apply correctly (teal/yellow/blue)
- BDL Import does NOT appear on Home (`show_on_home = 0`)
- Admin gear visible (Dirk is admin)
- JBoss page nav looks identical to before, with addition of Client Portal in the Tools section
- Active page highlighting works correctly

### Phase 3d — Remaining Route File Conversions (Complete 2026-04-29)

**Goal:** Convert all remaining route files to the dynamic nav pattern, retire duplicate nav CSS, and lift page header / browser title rendering into the registry.

**Helper module extensions delivered alongside the route work:**

1. **`Get-PageHeaderHtml`** — renders `<h1>` (linked to doc page when `doc_page_id` set, plain text otherwise) plus `<p class="page-subtitle">` from `RBAC_NavRegistry.display_title` and `description`. Single source of truth for page headers; route files no longer hardcode them.
2. **`Get-PageBrowserTitle`** — returns `"<display_title> - xFACts Control Center"` for the `<title>` element. Default suffix overridable via `-Suffix`.
3. **Admin gear active-state patch** — `Get-NavBarHtml` now applies the `active` class to the admin gear when `CurrentPageRoute = '/admin'`. Restores the visual indicator that was previously baked into the hand-written admin nav.

Both new functions exported and CHANGELOG updated.

**Routes converted in this phase (18 total, in delivery order):**

| Order | Route File | Page | Group |
|---|---|---|---|
| 1 | `ServerHealth.ps1` | /server-health | (standalone) |
| 2 | `JBossMonitoring.ps1` | /jboss-monitoring | (standalone — extended 3c) |
| 3 | `JobFlowMonitoring.ps1` | /jobflow-monitoring | 1 |
| 4 | `BatchMonitoring.ps1` | /batch-monitoring | 1 |
| 5 | `Backup.ps1` | /backup | 1 |
| 6 | `IndexMaintenance.ps1` | /index-maintenance | 1 |
| 7 | `DBCCOperations.ps1` | /dbcc-operations | 1 |
| 8 | `BIDATAMonitoring.ps1` | /bidata-monitoring | 2 |
| 9 | `FileMonitoring.ps1` | /file-monitoring | 2 |
| 10 | `ReplicationMonitoring.ps1` | /replication-monitoring | 2 |
| 11 | `DmOperations.ps1` | /dm-operations | 2 |
| 12 | `ApplicationsIntegration.ps1` | /departmental/applications-integration | 3 |
| 13 | `BusinessServices.ps1` | /departmental/business-services | 3 |
| 14 | `BusinessIntelligence.ps1` | /departmental/business-intelligence | 3 |
| 15 | `ClientRelations.ps1` | /departmental/client-relations | 3 |
| 16 | `Admin.ps1` | /admin | 4 |
| 17 | `ClientPortal.ps1` | /client-portal | 4 |
| 18 | `BDLImport.ps1` | /bdl-import | 4 |
| 19 | `PlatformMonitoring.ps1` | /platform-monitoring | 4 |

**Per-route conversion pattern (applied uniformly):**

1. Replace hardcoded `<nav>` block with `$navHtml = Get-NavBarHtml -UserContext $ctx -CurrentPageRoute '/X'`
2. Replace hardcoded H1+subtitle with `$headerHtml = Get-PageHeaderHtml -PageRoute '/X'`
3. Replace hardcoded `<title>` content with `$browserTitle = Get-PageBrowserTitle -PageRoute '/X'`
4. Remove the `$adminGear` variable + `$html.Replace('</nav>', "$adminGear</nav>")` plumbing
5. Strip duplicate nav-bar / nav-link / nav-spacer / nav-admin / nav-separator rules from the page-specific `.css` file
6. Opportunistic strip of other shared duplicates (scrollbar, refresh badges, page-refresh-btn, section-header-right, idle overlay, connection banner) where present

**Token replacements preserved:**
- `IndexMaintenance.ps1` and `DBCCOperations.ps1` — `__IS_ADMIN__` for admin-conditional UI features
- `DmOperations.ps1` — `__IS_ADMIN__` for admin-conditional Schedule and Abort buttons
- `BDLImport.ps1` — `__IS_ADMIN__` and `__USER_TIER__` for admin/tier-conditional rendering

**Group 3 simplification — `IsDeptOnly` branching dropped:**

`BusinessServices`, `BusinessIntelligence`, `ClientRelations`, and `ClientPortal` all previously had `if ($access.IsDeptOnly) { ... } else { ... }` branches that emitted a stripped-down nav for dept-only users. `Get-NavBarHtml` already filters nav items by user permissions, so a dept-only user naturally sees only Home + their department page. Three branches collapsed into a single helper call per file.

**Group 4 — Admin route quirks:**

- `Admin.ps1` retained its page-specific `.page-header` layout (different from the standard `.header-bar`). The page-specific `.nav-admin.active` rule was retained in `admin.css` to give the gear its teal active underline (the helper applies the class; `engine-events.css` doesn't currently style it).
- `PlatformMonitoring.ps1` — fixed a pre-existing bug where the `Get-UserAccess` check was passing `'/admin'` as the page route on a `/platform-monitoring` request. Now correctly uses `/platform-monitoring`.

**Group 4 — New shared infrastructure:**

1. **`engine-events-API.ps1`** (new file) — home for shared CC API endpoints that don't belong to a single page. Component `ControlCenter.Shared`. First endpoint:
   - `GET /api/nav-registry/label?route=<path>` — returns `{ "label": "<display_title>" }` for a CC route the requesting user has access to. Returns 404 in all other cases (route doesn't exist, user lacks access, etc.). Doubles as a "is this a place I can go?" check.

2. **Back-link feature** — added to `BDLImport.ps1` and `PlatformMonitoring.ps1`. Inline JS resolves `document.referrer` against the new endpoint:
   - If referrer maps to a CC route the user can access → "← Back to <referrer page label>" with `history.back()` behavior
   - Otherwise → fall back to "← Back to <Home label>" pointing at `/`, but only if user has Home access
   - Otherwise → link hidden entirely
   - Future tools rolled out to dept-only users will inherit this pattern (CSS lives in `engine-events.css` under `.back-link`).

3. **`engine-events-API` naming convention** established — see Architectural Decisions below.

**CSS cleanup highlights:**

- 18 page-specific CSS files trimmed of duplicate rules. Most aggressive cleanups: `dm-operations.css` (engine row stub, page-refresh-btn, refresh badges, connection banner block, idle overlay all removed) and `jboss-monitoring.css` (~102 lines removed, 821 → 719).
- Backup, BIDATA, FileMonitoring, JobFlow had full engine card blocks stripped.
- DmOps slide-panel rules **retained as page-specific** — page JS uses `.active` class to activate panels while shared CSS uses `.open`. Stripping would break the slideouts. Logged as a backlog item: align JS to `.open` then strip page-level rules.
- IndexMaintenance: mobile responsive nav-bar overrides retained as page-specific. ID-scoped slide-panel width overrides retained.

**Verified across all routes:**
- Nav identical across pages — full nav for IT users, dept-page-only for dept-only users
- Admin gear active state on `/admin`
- All token-driven UI features (BDL Import wizard, DmOps Schedule/Abort, Index Maintenance Launch badges) still functional
- Browser tab titles match page H1s
- Active page highlighting consistent

---

## What's Pending

### Backlog

| Priority | Item | Notes |
|---|---|---|
| Medium | DmOps slide-panel `.active`→`.open` JS alignment | DmOps `dm-operations.js` activates slide panels with `.active` while shared `engine-events.css` uses `.open`. Currently working because page-level CSS retains the `.active`-keyed slide-panel rules. To complete the cleanup: change JS to use `.open` and strip the page-level slide-panel rules. Out-of-scope for Phase 3d. |
| Medium | DBCC disk space alert suppression | When CHECKDB FULL is running, ServerHealth disk alerts can fire incorrectly because the operation temporarily inflates disk usage. Cross-component awareness needed: ServerHealth alerting should suppress (or annotate) disk alerts on a server while DBCC is active there. |
| Medium | Coverage gap-check refinement | `/admin` and `/platform-monitoring` show as false positives in NavRegistry vs PermissionMapping gap check because they rely on Admin role's wildcard `*` permission. Decide between query-side fix (special-case in CTE) or schema-side fix (add `requires_explicit_permission` BIT flag to NavRegistry). |
| Medium | Doc-page RBAC integration | Apply the same RBAC + dynamic nav approach to `/docs/pages/*`. Requires: (1) auth on currently-unauthenticated `/docs` static route in Start-ControlCenter.ps1, (2) doc page → CC page route → permission lookup, (3) nav.js update to receive filtered registry. The `doc_page_id` field in NavRegistry is the join key (slashes in slug already supported, see arch decisions). Significant — own session. |
| Low | Engine-events naming convention documentation | Add a note to `xFACts_Development_Guidelines.md` codifying that `engine-events.css`, `engine-events.js`, and `engine-events-API.ps1` are the canonical files for cross-page CC infrastructure (CSS/JS/API respectively). Future shared endpoints belong in `engine-events-API.ps1`. |
| Low | BusinessIntelligence header live indicator | BI page header has no live indicator. Add one if/when real-time data sources are wired up to this page. |
| Low | Re-evaluate `mapping_id 13` style scoped mappings | If future work introduces UI features that genuinely use `DepartmentScopes`, may need to reintroduce role-scoped mappings (with intent this time). Document the use case before adding. |

---

## Architectural Decisions

### Why a separate `RBAC_NavRegistry` table instead of extending `Component_Registry`?

`Component_Registry` is doc-site oriented and many components have no CC page. The NavRegistry needs to be the source of truth for "what CC pages exist." Storing CC nav metadata in Component_Registry would:
- Add 5+ mostly-NULL columns to a table that already does a lot
- Conflate "this component has documentation" with "this is a CC page"
- Make joins from `RBAC_PermissionMapping.page_route` indirect

Separate table won. The two registries connect on the `doc_page_id` value, which is the same convention used in Component_Registry.

### Why include Home as universal first link instead of as a NavRegistry row?

- Home is unique — it has no section it really belongs to
- It's always first in nav, regardless of section
- Modeling it in NavRegistry would require special-case sort_order handling

Cleaner for the helper to hardcode "Home as first link" than to have a special row in the data.

### Why decouple `show_in_nav` and `show_on_home`?

Some pages need different visibility per surface:
- `/client-portal` — appears in nav AND home tiles
- `/bdl-import` — accessed only via tile from Apps/Int and BI; not in nav, not on home
- `/admin` — accessed only via gear icon; nowhere else
- `/platform-monitoring` — accessed only via admin modal; nowhere else

A single visibility flag couldn't capture all combinations. Two flags cleanly model the actual use cases.

### Why store `accent_class` on NavSection instead of literal colors?

- Colors aren't a database concern — they're presentation
- Decouples styling decisions (hover effects, dark mode variants, branding) from data
- Stores intent (`departmental` styling) rather than implementation (`#dcdcaa`)
- Existing platform pattern (`.dept-card` class) was already class-based

### Why is admin section in registry but not rendered?

Inventory completeness. Treating NavRegistry as the master CC page catalog means admin-only pages should be there too — for management, future doc-page RBAC integration, and discoverability via the registry. The helper functions skip rendering them because:
- `show_in_nav = 0` and `show_on_home = 0` exclude them from those surfaces
- The helper additionally skips the entire `admin` section in nav (defensive)

If a future feature wants to enumerate "all CC pages including admin," the data is there.

### `doc_page_id` slug accepts subfolder paths

The helper's URL construction (`/docs/pages/{doc_page_id}.html`) HtmlEncodes the slug but does not strip slashes. Confirmed working in Phase 3d with paths like `cc/controlcenter-cc-platform`, `cc/controlcenter-cc-admin`, and `guides/bdl-import-guide`. This means CC pages can link to their CC-specific reference docs (under `/docs/pages/cc/`) or to guide pages (under `/docs/pages/guides/`) without code changes — just set the `doc_page_id` to the relative path.

Useful side effect: when doc-page RBAC integration happens in a future session, the join key naturally supports the existing folder structure.

### `engine-events-API.ps1` naming convention

`engine-events.css` and `engine-events.js` are the established shared-infrastructure files for the Control Center. With Phase 3d's introduction of `engine-events-API.ps1`, this becomes the canonical naming convention for cross-page CC infrastructure across all three layers:

- `engine-events.css` — shared styles (nav, modals, scrollbars, refresh badges, slide panels, back-link, ...)
- `engine-events.js` — shared client-side helpers (engine card updates, modals, idle handling, ...)
- `engine-events-API.ps1` — shared server-side endpoints (nav registry label lookup, future shared endpoints)

The alternative ("rename everything to `shared.*`") was considered and rejected — too invasive given the existing footprint, and the `engine-events` prefix is already deeply embedded in component classification, file references, and developer mental models. Future shared endpoints (idle/session helpers, label resolvers, anything reusable by 2+ pages) belong in `engine-events-API.ps1` rather than getting their own file.

This convention should be codified in `xFACts_Development_Guidelines.md` (backlog item).

### Why a `/api/nav-registry/label` endpoint rather than embedding labels in JS?

The back-link feature on tool pages (BDLImport, PlatformMonitoring) needs to resolve `document.referrer` to a display label, but only if the user has access to that route. Three options were considered:

1. **Embed all labels in a JS bundle on every page** — simple but leaks the full nav inventory to every browser, ignoring RBAC.
2. **Add a `referrer` parameter to every page render** — server picks the label and passes it to JS. Means every page needs to know about the back-link feature. Tight coupling.
3. **Endpoint approach (chosen)** — JS reads `document.referrer`, calls `/api/nav-registry/label?route=<path>`, gets back either a label or 404. Server enforces RBAC; client gets only what the user is allowed to know.

Option 3 also doubles as a "is this route accessible to me?" probe, which the back-link uses for its Home fallback. Single endpoint, two use cases, RBAC enforced server-side.

---

## Active Configuration Snapshot

These are the GlobalConfig settings driving RBAC behavior, current as of 2026-04-29:

| Setting | Value | Purpose |
|---|---|---|
| `ControlCenter.RBAC.rbac_enforcement_mode` | `enforce` | Active enforcement |
| `ControlCenter.RBAC.rbac_audit_verbosity` | `all` | Logs all events including ALLOWED (drop to `denials_only` once confident) |

### Cache refresh

- `RBACCache` refreshes every 5 minutes (`CacheDurationSec = 300` in xFACts-Helpers.psm1)
- CC restart forces immediate refresh
- Cache covers: Roles, RoleMappings, PagePermissions, ActionGrants, ActionRegistry, DepartmentPages, NavSections, NavRegistry, EnforcementMode, AuditVerbosity

---

## Files Changed This Effort

| File | Change Type | Phase |
|---|---|---|
| `dbo.RBAC_PermissionMapping` | INSERT × 6, DELETE × 1 | 0 |
| `dbo.RBAC_DepartmentRegistry` | UPDATE × 1 | 0 |
| `dbo.RBAC_RoleMapping` | DELETE × 1 (mapping_id 13) | 0.5 |
| `Legacy.RBAC_AuditLog_Archive_PreEnforcement` | CREATE | 0 |
| `dbo.RBAC_AuditLog` | TRUNCATE | 0 |
| `dbo.GlobalConfig` | UPDATE × 1 (enforcement mode) | 0 |
| `dbo.RBAC_NavSection` | CREATE TABLE + INSERT × 4 | 1 |
| `dbo.RBAC_NavRegistry` | CREATE TABLE + INSERT × 20 | 1 |
| `dbo.Object_Metadata` | INSERT × ~30 (baselines + enrichment) | 1 |
| `dbo.Object_Registry` | INSERT × 2 | 1 |
| `xFACts-Helpers.psm1` | Full file replacement (Phase 2 — nav helpers; Phase 3d — page header / browser title helpers + admin gear active patch) | 2, 3d |
| `engine-events.css` | Phase 3a: nav classes appended. Phase 3d: `.back-link` block appended. | 3a, 3d |
| `Home.ps1` | Full file replacement | 3b |
| `JBossMonitoring.ps1` | Full file replacement (Phase 3c proof-of-concept; Phase 3d browser title + header from registry) | 3c, 3d |
| `ServerHealth.ps1` | Browser title from registry | 3d |
| `JobFlowMonitoring.ps1`, `BatchMonitoring.ps1`, `Backup.ps1`, `IndexMaintenance.ps1`, `DBCCOperations.ps1` | Full file replacement (Group 1) | 3d |
| `BIDATAMonitoring.ps1`, `FileMonitoring.ps1`, `ReplicationMonitoring.ps1`, `DmOperations.ps1` | Full file replacement (Group 2) | 3d |
| `ApplicationsIntegration.ps1`, `BusinessServices.ps1`, `BusinessIntelligence.ps1`, `ClientRelations.ps1` | Full file replacement (Group 3) | 3d |
| `Admin.ps1`, `ClientPortal.ps1`, `BDLImport.ps1`, `PlatformMonitoring.ps1` | Full file replacement (Group 4) | 3d |
| `engine-events-API.ps1` | NEW FILE — shared API endpoints (`/api/nav-registry/label`) | 3d |
| 18 × page-specific `.css` files | Duplicate nav block stripped + opportunistic shared-rule cleanup | 3d |

---

## Known Issues / Watch Items

1. **`/admin` and `/platform-monitoring` show in coverage gap-check** — known false positive. They rely on Admin role's `*` wildcard, not explicit page rows. Acceptable for now; refinement is a backlog item.

2. **DmOps slide-panel JS/CSS class mismatch** — DmOps page JS uses `.active` to activate slide panels, while shared `engine-events.css` uses `.open`. Currently working because page-level `dm-operations.css` retains the `.active`-keyed slide-panel rules. Logged in backlog as "DmOps slide-panel `.active`→`.open` JS alignment."

---

## Pickup Checklist for Next Session

When resuming this work in a new session:

1. Read this document first.

2. Run the coverage gap-check query to confirm state hasn't drifted:
   ```sql
   WITH nav_pages AS (
       SELECT DISTINCT page_route FROM dbo.RBAC_NavRegistry WHERE is_active = 1
   ),
   perm_pages AS (
       SELECT DISTINCT page_route
       FROM dbo.RBAC_PermissionMapping
       WHERE is_active = 1
         AND page_route NOT IN ('*', '/')
   )
   SELECT
       COALESCE(n.page_route, p.page_route) AS page_route,
       CASE
           WHEN n.page_route IS NULL THEN 'In PermissionMapping only - missing NavRegistry row'
           WHEN p.page_route IS NULL THEN 'In NavRegistry only - missing PermissionMapping row'
       END AS gap_description
   FROM nav_pages n
   FULL OUTER JOIN perm_pages p ON p.page_route = n.page_route
   WHERE n.page_route IS NULL OR p.page_route IS NULL
   ORDER BY page_route;
   ```
   Expected: `/admin` and `/platform-monitoring` only (acceptable false positives).

3. Verify Phase 3d outcome — quick visual pass across all 18 routes confirming nav, header, browser title, and active state work as expected.

4. Pick up next session items (in roughly this priority order):
   - **DmOps slide-panel `.active`→`.open` JS alignment** — small/medium cleanup. Once done, strip the page-level slide-panel rules from `dm-operations.css`.
 
5. Doc-page RBAC integration is a separate, larger session — don't tackle until smaller follow-ups are clear.

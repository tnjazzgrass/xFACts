# RBAC Enforcement & Dynamic Nav Working Document

**Created:** April 29, 2026  
**Status:** Active — Phase 3d in progress  
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
| `doc_page_id` | VARCHAR(50) NULL | Doc slug; URL built as `/docs/pages/{doc_page_id}.html` |
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

**Known acceptable inconsistency:** Other route files still have hardcoded nav blocks. Their navs do NOT yet include Client Portal or apps-integration as visible nav items. This will be resolved in Phase 3d.

---

## What's Pending

### Phase 3d — Remaining Route File Conversions (Next Session)

**~16 route files** to update with the same pattern as JBossMonitoring.ps1. For each route:

1. Replace hardcoded `<nav>` block with `$navHtml = Get-NavBarHtml -UserContext $ctx -CurrentPageRoute '/X'`
2. Embed `$navHtml` in the HTML output
3. Remove the manual admin-gear append logic (`$adminGear` variable + `.Replace('</nav>', "$adminGear</nav>")`)
4. **Optional concurrent cleanup**: strip duplicate `.nav-bar`, `.nav-link`, `.nav-separator`, `.nav-admin`, `.nav-spacer` rules from the page's `.css` file (now lives in `engine-events.css`)

**Routes to convert (in suggested order):**

| Order | Route File | Page |
|---|---|---|
| 1 | `Admin.ps1` | /admin |
| 2 | `ServerHealth.ps1` | /server-health |
| 3 | `JobFlowMonitoring.ps1` | /jobflow-monitoring |
| 4 | `BatchMonitoring.ps1` | /batch-monitoring |
| 5 | `Backup.ps1` | /backup |
| 6 | `IndexMaintenance.ps1` | /index-maintenance |
| 7 | `DBCCOperations.ps1` | /dbcc-operations |
| 8 | `BIDATAMonitoring.ps1` | /bidata-monitoring |
| 9 | `FileMonitoring.ps1` | /file-monitoring |
| 10 | `ReplicationMonitoring.ps1` | /replication-monitoring |
| 11 | `DmOperations.ps1` | /dm-operations |
| 12 | `ApplicationsIntegration.ps1` | /departmental/applications-integration |
| 13 | `BusinessServices.ps1` | /departmental/business-services |
| 14 | `BusinessIntelligence.ps1` | /departmental/business-intelligence |
| 15 | `ClientRelations.ps1` | /departmental/client-relations |
| 16 | `ClientPortal.ps1` | /client-portal |
| 17 | `BDLImport.ps1` | /bdl-import |
| 18 | `PlatformMonitoring.ps1` | /platform-monitoring |

**Suggested batching:** Could be done in groups of 4-6 per session for easy verification. All-at-once is also viable since the change pattern is mechanical.

**Reference files to model after:** `JBossMonitoring.ps1` (Phase 3c proof-of-concept) is the canonical pattern.

### Backlog Items From This Work

| Priority | Item | Notes |
|---|---|---|
| Medium | Coverage gap-check refinement | `/admin` and `/platform-monitoring` show as false positives in NavRegistry vs PermissionMapping gap check because they rely on Admin role's wildcard `*` permission. Decide between query-side fix (special-case in CTE) or schema-side fix (add `requires_explicit_permission` BIT flag to NavRegistry). |
| Medium | Drop verbosity to `'denials_only'` | Currently `rbac_audit_verbosity = 'all'` which logs every access check. Drop once confident in enforcement. Single GlobalConfig UPDATE. |
| Medium | Doc-page RBAC integration | Apply the same RBAC + dynamic nav approach to `/docs/pages/*`. Requires: (1) auth on currently-unauthenticated `/docs` static route in Start-ControlCenter.ps1, (2) doc page → CC page route → permission lookup, (3) nav.js update to receive filtered registry. The `doc_page_id` field in NavRegistry is the join key. Significant — own session. |
| Low | Strip duplicate nav-bar CSS from page-specific files | Phase 3d should do this opportunistically per-route. After Phase 3d, do a final sweep to confirm all `.nav-bar` / `.nav-link` rules in page-specific CSS are removed. |
| Low | `/admin` documentation page | Currently `doc_page_id = NULL`. Possible future: dedicated admin doc page. There's a `controlcenter-cc-admin.html` CC guide but no full narrative/ref. |
| Low | engine-events.css/js rename | The file has become the de facto shared CC file but the name is misleading. Possibly split into truly shared (engine-events) vs CC-shared content. Already in backlog under ControlCenter.Shared. |
| Low | `/departmental/applications-integration` page split | DM vs B2B sections. Currently PowerUser specializes in DM, StandardUser in IBM/B2B. UI hides DM-specific sections from StandardUser via role checks. Defer until B2B build matures. |
| Low | Re-evaluate `mapping_id 13` style scoped mappings | If Phase 3d or future work introduces UI features that genuinely use `DepartmentScopes`, may need to reintroduce role-scoped mappings (with intent this time). Document the use case before adding. |
| Low | Populate descriptions for all NavRegistry rows | In progress — Dirk handling manually. Confirm completion next session. |

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
| `xFACts-Helpers.psm1` | Full file replacement | 2 |
| `engine-events.css` | Nav classes appended | 3a |
| `Home.ps1` | Full file replacement | 3b |
| `JBossMonitoring.ps1` | Full file replacement | 3c |

**System_Metadata bumps needed** (do at end of each session):

| Module | Component | Reason |
|---|---|---|
| `dbo` | `Engine.RBAC` | NavSection/NavRegistry tables added (Phase 1) |
| `ControlCenter` | `ControlCenter.Shared` | Helper additions + RBAC_AuditLog cleanup + enforcement flip + nav CSS additions (Phase 0/2/3a) |
| `ControlCenter` | `ControlCenter.Home` | Dynamic tile rendering (Phase 3b) |
| `JBoss` | `JBoss` | Dynamic nav adoption (Phase 3c) |

After Phase 3d, additional bumps will be needed for each route updated.

---

## Known Issues / Watch Items

1. **`/admin` and `/platform-monitoring` show in coverage gap-check** — known false positive. They rely on Admin role's `*` wildcard, not explicit page rows. Acceptable for now; refinement is a backlog item.

2. **Other route files still have hardcoded navs** — they're functional but visually inconsistent with the dynamic nav (no Client Portal in their nav bars, etc.). Resolved by Phase 3d.

3. **CSS rule duplication during transition** — both `engine-events.css` and page-specific CSS files have nav rules. They're identical, so no visual conflict. Cleanup is part of Phase 3d.

4. **Verbosity is `all`** — every page access generates an audit log row. Volume should be modest given current usage, but monitor and drop to `denials_only` once enforcement is proven solid.

---

## Pickup Checklist for Next Session

When resuming this work in a new session:

1. Read this document first
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

3. Check current state of NavRegistry descriptions — they may now be populated.

4. Pick up Phase 3d. Reference `JBossMonitoring.ps1` as the canonical conversion pattern. Consider doing in batches of 4-6 routes per deployment.

5. As Phase 3d completes each route, also strip duplicate `.nav-bar`, `.nav-link`, `.nav-separator`, `.nav-admin`, `.nav-spacer` rules from the page-specific CSS file.

6. After Phase 3d completion, decide on:
   - Coverage gap-check refinement (query side or schema side)
   - Drop verbosity to `denials_only`

7. Doc-page RBAC integration is a separate future session — don't tackle until Phase 3d is complete.

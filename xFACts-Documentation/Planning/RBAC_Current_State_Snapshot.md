# xFACts RBAC — Current State Snapshot

**Date:** 2026-05-15 (revised post-WebSocket-resolution)
**Purpose:** Reference snapshot of what xFACts RBAC looks like today, after a full walkthrough of the data, code, and observed behavior. Not a fix-it document — a "where we are" document. Compare against existing CC RBAC documentation to identify drift.

---

## 1. The Model at a Glance

xFACts RBAC is organized around four concepts that interact during access resolution:

| Concept | Where it lives | What it answers |
|---|---|---|
| **Role** | `RBAC_Role` | "What kind of user am I?" |
| **Tier** | `permission_tier` on `RBAC_PermissionMapping` | "What level of action can I perform on a given page?" |
| **Department scope** | `department_scope` on `RBAC_RoleMapping` | "Which department am I tied to, if any?" |
| **Action grant** | `RBAC_ActionGrant` | "Are there overrides for my specific role/user that ALLOW or DENY a specific action?" |

These are layered. A user's effective access for any page/action is the result of combining all four. Resolution always begins with AD groups and works inward.

## 2. The Eight Tables

| Table | Purpose | Notes |
|---|---|---|
| `RBAC_Role` | Catalog of roles. Currently 6 active. | `role_tier` column exists but is metadata-only — not used in resolution logic. |
| `RBAC_RoleMapping` | AD group → role mapping, with optional `department_scope`. | Each AD group resolves to exactly one role. The same role (e.g., DeptManager) is reused across multiple AD groups, with scope as the discriminator. |
| `RBAC_PermissionMapping` | Role → page route → tier. | Wildcard `*` page route allowed (Admin uses it). Currently 60 rows. |
| `RBAC_DepartmentRegistry` | Department key → dept page route mapping. | 5 rows; Finance/Accounting is a forward declaration (no page yet). |
| `RBAC_NavRegistry` | Master inventory of CC pages with nav metadata. | Carries `is_active`, `show_in_nav`, `show_on_home` flags. |
| `RBAC_NavSection` | Section groupings (`platform`, `departmental`, `tools`, `admin`) with accent colors. | Drives both nav bar layout and Home page tile grouping. |
| `RBAC_ActionRegistry` | Catalog of API endpoints that require explicit tier declarations. | 19 rows; not comprehensive — see Section 5. |
| `RBAC_ActionGrant` | User or role-level ALLOW/DENY overrides for specific actions. | 1 row today (ReadOnly users can kill zombie sessions). |
| `RBAC_AuditLog` | Every permission decision logged. | Verbose, working as designed. |

## 3. Roles in Current Use

| Role | Tier | Active users | Intent |
|---|---|---|---|
| Admin | admin | 4 | Full site access incl. `/admin` |
| PowerUser | operate | 3 | Full site access minus admin functions |
| StandardUser | operate | 3 | Similar to PowerUser, slightly more restricted |
| ReadOnly | view | 7-8 | View access to all platform pages |
| DeptManager | operate | (overlapping with ReadOnly users) | Elevated access to their own dept page |
| DeptStaff | operate | 0 (likely sunset candidate) | Reduced dept access; never used |

**Important pattern:** Every current DeptManager user is *also* assigned ReadOnly. There is no user with DeptManager alone. This dual-role assignment is the basis of dept users getting platform-page view access in addition to their own dept page operate access.

## 4. Access Resolution Logic (How It Actually Works)

Resolution happens in `xFACts-Helpers.psm1`, primarily in `Get-UserPageTier`. Simplified flow:

1. User logs in. Pode authenticates against AD and captures the user's full AD group membership.
2. On every page request, `Get-UserAccess` is called for the requested page route.
3. `Resolve-UserRoles` matches AD groups against `RBAC_RoleMapping` rows to produce a list of resolved roles (each with optional `department_scope`).
4. `Get-UserPageTier` walks the user's roles and checks `RBAC_PermissionMapping` rows for matches on the requested page route.
5. For each matching permission row:
   - Verify the user actually holds the role
   - Verify the page route matches (exact or wildcard `*`)
   - **If the user's role has a `department_scope` AND the permission row is a wildcard, additionally verify the page route is in that department's scope.** This filter does NOT apply to non-wildcard permission rows. (This is the source of the dept-nav leak — see Section 6.)
6. The highest tier across all matching permissions is returned.
7. If no tier resolves, `HasAccess` is false (unless enforcement mode is `audit` or `disabled`).

For action-level permissions, `Test-ActionPermission` follows this order:
USER DENY > ROLE DENY > USER ALLOW > ROLE ALLOW > tier-based fallback

## 5. Enforcement Patterns Found in Routes

Walking through actual route files revealed **three different patterns** for endpoint protection, suggesting inconsistent application of the dev guidelines:

**Pattern A — `Test-ActionEndpoint` + `RBAC_ActionRegistry` row**
The textbook pattern. Endpoint is registered in ActionRegistry, route calls `Test-ActionEndpoint` first. Fully protected with tier check and grant override support.
*Examples:* `/api/admin/toggle-process`, `/api/server-health/kill-zombies`
*Count today:* roughly the 19 endpoints in ActionRegistry

**Pattern B — Manual `Get-UserAccess` page-level check**
Author calls `Get-UserAccess` against a related page route and gates on `HasAccess`. Page-level only — no tier check, no grant overrides.
*Examples:* `/api/apps-int/balance-sync` and other apps-int endpoints
*Implication:* Works for current use cases but doesn't honor tier requirements. A view-only user with page access would pass.

**Pattern C — No RBAC check at all**
Route only requires `-Authentication 'ADLogin'`. Any authenticated user can call it.
*Examples:* `/api/bdl-import/execute`, most `/api/bdl-import/*` endpoints
*Implication:* The mutating action runs for anyone logged in who knows the URL. UI hides the buttons, but URL discovery bypasses the UI.

**Endpoint inventory:** Asset_Registry currently captures 245 route definitions across the platform: 191 GET, 52 POST, 1 PUT, 1 DELETE. Of the 54 mutating endpoints, 19 are catalogued in `RBAC_ActionRegistry`. The remaining 35 fall into Pattern B or C.

## 6. The Dynamic Navigation Layer

The horizontal nav bar and Home tile grid are rendered server-side by `Get-NavBarHtml` and `Get-HomePageSections`, sourced from `RBAC_NavRegistry`. They filter pages by user permissions silently (no audit log entries) and apply section accent colors.

The nav rendering uses `Get-UserPageTier` for filtering — meaning a user only sees nav links to pages they have a resolved tier for. **This means the dept-nav leak (Section 7) affects both nav rendering AND actual page access through the same code path.**

## 7. Content Filtering Layer — `Tools.AccessConfig` and `Tools.AccessFieldConfig`

These are not RBAC tables but live alongside them. They control content visibility within the BDL Import page based on `department_scope`:

- `Tools.AccessConfig` — limits which BDL processes a department can see (of the ~70 in the catalog, the visible subset, then narrowed further per department)
- `Tools.AccessFieldConfig` — limits which fields within a BDL process a department can interact with

**Relationship to RBAC:** Both tables key on `department_scope`, which is read from the user's resolved roles via the RBAC layer. The same scope value drives both nav filtering and content filtering. This is a coupling worth being aware of — if RBAC's handling of `department_scope` changes, content filtering is implicitly affected.

**Important caveat:** These are UI-rendering filters, not server-side authorization. A user crafting a direct POST to `/api/bdl-import/execute` is not validated against their `AccessFieldConfig` rows. Field-level restrictions today are honest-user protections only.

## 8. Identified Gaps and Observations

### 8.1 Dept-Nav Leak (Active Bug)
DeptManager has explicit `RBAC_PermissionMapping` rows for all four departmental page routes. The `department_scope` filter in `Get-UserPageTier` only fires for wildcard (`*`) permissions, not explicit page rows. Result: any DeptManager-scoped user sees all four dept pages in the nav and can navigate to any of them. The same path applies to actual page access — Brandon (BI scope) can load `/departmental/business-services` if he types the URL.

### 8.2 Endpoint Protection Inconsistency
Three different enforcement patterns exist in production code (see Section 5). 35 mutating endpoints have no explicit registry/tier protection. For tools like BDL Import specifically, this means a malicious or careless authenticated user could trigger imports they're not supposed to perform.

### 8.3 BDL Import Has No Endpoint-Level Authorization
The `/api/bdl-import/execute` endpoint executes against Debt Manager via the FICO REST API with **no RBAC check at all**. Today the protection is:
- Page-level access via `RBAC_PermissionMapping` (which itself has the dept-nav leak)
- UI content filtering via `Tools.AccessConfig`/`AccessFieldConfig`

A direct POST bypasses both.

### 8.4 Dead/Inactive Permission Rows
The `DeptManager | /bdl-import | operate` row currently grants access to all DeptManager users regardless of scope. Per the discussion of pattern (c) — "specific dept managers can have access to specific tools" — this is over-permissive.

### 8.5 WebSocket Disconnect — RESOLVED (Network Layer)
Users in the ReadOnly + DeptManager population were experiencing persistent "disconnected" banners on platform pages. After investigation, the root cause was identified as **Palo Alto firewall App-ID inspection blocking WebSocket-classified traffic** from these users to FA-SQLDBB. Initial HTTP handshakes succeeded (returning 101 Switching Protocols), but the firewall dropped the upgraded connection within ~25ms during L7 inspection. IT users were unaffected because the `Applications` AD group has explicit firewall pass-through.

The role-membership correlation was real but spurious — affected users tended to lack the IT-administrative AD groups that included firewall pass-through rules. **The xFACts code, RBAC model, and Pode framework were never the cause.**

Resolution: Shawn (Infrastructure) added firewall rules for IKE (port 500) and WebSocket App-ID pass-through to FA-SQLDBB. Confirmed clear for Brandon, Allison, and Michelle on 2026-05-15.

### 8.6 Pode Error Logging Disabled
No Pode error logs have been written in approximately 3 months. This is silent. We cannot use logs to diagnose runtime issues until logging is restored. Out of scope for the RBAC audit but flagged.

### 8.7 `engine-events-API.ps1` References Undefined Function
The `/api/nav-registry/label` endpoint calls `Get-SqlData` which is not defined in `xFACts-Helpers.psm1`. Either the endpoint has been silently broken since deployment, or the function is defined elsewhere we haven't seen. Worth verifying.

## 9. Open Design Questions

These are questions that came up during the walkthrough and don't have clear answers from existing architecture alone. Each will require deliberate decisions before final implementation.

### 9.1 Number of Base Levels
PowerUser, StandardUser, and ReadOnly are differentiated but the differences may be marginal given that ~90% of the site is naturally view-only and most write actions are admin-gated. Worth considering whether 4 base levels is the right number — open question for design discussion, not driven by any active issue.

### 9.2 Per-Scope Tool Access (Pattern C)
Today's design allows a permission row to grant access to a page across all users of a role, but doesn't express "this scope of users gets access to this page, those don't." For BDL Import specifically, BI and Apps/Int dept managers should have access, Business Services and Client Relations should not. The current row grants access to all DeptManager users. Approaches discussed:
- New `applies_to_scope` column on `RBAC_PermissionMapping`
- New separate table `RBAC_ScopePermissionMapping`
- New `is_scope_exempt` flag (rejected — doesn't solve per-dept granularity)

### 9.3 DeptStaff Sunsetting
Role exists, has permission rows, but no users are assigned. Likely safe to deactivate but should be deliberate, not orphaned.

### 9.4 Endpoint Protection Standardization
Now that `Asset_Registry` is producing a comprehensive endpoint catalog, a default rule could be codified:
- GET endpoints: page-level access via `Get-UserAccess` is sufficient
- Mutating endpoints (POST/PUT/DELETE): must call `Test-ActionEndpoint` AND have an `RBAC_ActionRegistry` row
- Internal/auth endpoints: documented exceptions

This would let us build a gap report from Asset_Registry that shows every endpoint not compliant with the rule.

### 9.5 RBAC vs. Content-Filtering Separation
`Tools.AccessConfig` and `Tools.AccessFieldConfig` exist because RBAC couldn't express the granularity BDL needs. Worth deciding whether this separation should persist as a pattern (each tool gets its own access tables), or whether a more expressive RBAC model could subsume some of it. Note that field-level granularity may be too domain-specific for generic RBAC.

## 10. Things Working Well

For balance, these are working as designed and don't require attention:

- AD group → role resolution
- The 5-minute cache refresh in `Confirm-RBACCache`
- Pattern A endpoint protection (where applied)
- `Get-NavBarHtml` and `Get-HomePageSections` filtering logic (independent of the underlying scope-filter bug)
- `Tools.AccessConfig`/`AccessFieldConfig` for UI-level content filtering — does what it's meant to do
- Audit logging via `Write-RBACAuditLog` and `RBAC_AuditLog`
- `Get-UserContext` as the lightweight identity helper for UI rendering
- Login event capture and failure handling with flash messages
- The wildcard `*` Admin permission pattern
- Section accent class application across nav and tiles

---

## Footnotes

This document represents the state as of the 2026-05-15 audit session. Numbers and observations are based on data and code snapshots taken during the session and may shift slightly with subsequent changes. Use this as a comparison reference against the CC documentation site's existing RBAC pages, not as a replacement for them.

# BDL Import Module -- Working Document

**Status:** In development -- Steps 1-6 functional, end-to-end tested on TEST and PROD  
**Audience:** Dirk, Matt, Brandon, Claude  
**Last Updated:** April 4, 2026  
**Replaces:** `BDL_Import_Module_Design.md`, `BDL_Catalog_Reload_Instructions.md`, `xFACts_Questions_For_Matt.md`

---

## Overview

A Control Center page (`/bdl-import`) that allows authorized users to upload a vendor data file, map its columns to BDL fields via click-to-pair or drag-and-drop, validate the data against DM reference tables, preview the generated XML, and trigger a BDL import into Debt Manager. Accessible via card links from the Applications & Integration page (IT team) and the Business Intelligence page (BI team). RBAC controls page access; `Tools.AccessConfig` controls entity-level access per department; `Tools.AccessFieldConfig` controls field-level access per department (strict whitelist).

---

## Current State

### What's Built and Deployed

**Database infrastructure (Tools schema):**
- `tools_enabled` column on `dbo.ServerRegistry` -- master switch for Tools server participation (7 app servers enabled)
- `Tools.ServerConfig` -- 3 rows (one per environment) with API URLs, dmfs paths, `db_instance`, and pipeline folder names for environment-specific targeting
- `Tools.AccessConfig` -- department-scoped entity access control (BI seeded with PHONE only)
- `Tools.AccessFieldConfig` -- field-level whitelist, child of AccessConfig. Strict whitelist: no child rows = zero field access. Admin tier bypasses entirely. BI seeded with `is_import_required` PHONE fields.
- `Tools.BDL_ImportLog` -- import execution audit trail with lifecycle status tracking, `column_mapping` JSON, `value_changes` column for replacement audit, and `file_registry_id` from DM API
- `Tools.BDL_ImportTemplate` -- saved column mapping templates for vendor-specific file layouts. Columns: `template_id` (PK), `entity_type`, `template_name`, `description`, `column_mapping` (JSON), `is_active`, audit columns. Unique constraint on `entity_type + template_name`. Object_Registry and Object_Metadata baselines created.
- `Staging` schema -- created for temporary import staging tables (not registered in xFACts platform, invisible to documentation pipeline)
- `AVG-STAGE-LSNR` added to `dbo.ServerRegistry` (AG_LISTENER, STAGE, DMSTAGEAG, is_active=0)
- `Tools.Operations` component -- registered and baselined

**DM API Integration (fully operational):**
- `dbo.CredentialServices` row for `DM_REST_API`
- `dbo.Credentials` rows for Username, Password, and AuthHeader (two-tier encrypted)
- Auth pattern mirrors Matt's legacy VBA toolkit exactly: `Authorization` header passed through as-is from stored `AuthHeader` value, `Content-Type: application/vnd.fico.dm.v1+json`
- API flow: POST `/fileregistry` (register file, extract `data.fileRegistryId` from response) -> POST `/fileregistry/{id}/bdlimport` (trigger import)
- File write uses BOM-less UTF-8 encoding (`New-Object System.Text.UTF8Encoding($false)`) -- DM's XML parser rejects BOM

**Catalog enrichment:**
- `format_id` integer FK added to `Catalog_BDLElementRegistry` and `Catalog_CDLElementRegistry` (replaces composite FK)
- `is_visible` and `is_import_required` columns on both element registry tables
- `display_name VARCHAR(100)` on both element registry tables -- human-readable field names for mapping UI
- `is_active BIT` on both format registry tables -- controls entity availability
- Field descriptions enriched from SchemaSpy DM database column comments (682 verified descriptions)
- `is_not_nullifiable` and `is_primary_id` populated from Excel interface definition
- `table_column` and `lookup_table` populated from Excel interface definition
- `is_visible = 0` set on unreliable identifier fields and primary ID fields
- `is_import_required` flags set by Matt for PHONE entity
- All `spec_version` hardcoded filters removed from API queries -- catalog data filtered by `is_active` and `is_visible` only

**Shared helpers:**
- `Invoke-XFActsNonQuery` added to `xFACts-Helpers.psm1` -- ExecuteNonQuery() for DDL and DML operations against xFACts database
- `Build-BDLXml` added to `xFACts-Helpers.psm1` -- constructs BDL XML from staging table data and catalog metadata
- `Get-ServiceCredentials` in `xFACts-Helpers.psm1` -- two-tier decryption for DM API credentials

**Control Center pages:**
- `BDLImport.ps1` / `BDLImport-API.ps1` / `bdl-import.js` / `bdl-import.css` -- BDL Import wizard page
- Two-column layout: 65% left (stepper bar + action panels) / 35% right (compact step guide + template section)
- Shared `engine-events.css` linked for slideout panel pattern and shared visual standards
- `ApplicationsIntegration.ps1` / `applications-integration.css` -- Apps/Int departmental page under `DeptOps.ApplicationsIntegration`
- BI page updated: BDL Import card now links to `/bdl-import`
- SheetJS `xlsx.full.min.js` v0.20.3 hosted locally for client-side Excel parsing

**RBAC:**
- BDL Import page: Admin (wildcard), PowerUser/StandardUser = admin tier, ReadOnly = view, DeptStaff/DeptManager = operate
- Admin tier on BDL Import = unrestricted entity and field access (bypasses AccessConfig and AccessFieldConfig)
- Operate tier on BDL Import = entities filtered by AccessConfig, fields filtered by AccessFieldConfig (strict whitelist)
- **Middleware fix applied:** `Get-UserPageTier` in `xFACts-Helpers.psm1` updated so department-scoped roles are honored on non-departmental pages when an explicit permission row exists.
- **DBNull handling:** API endpoints use `-isnot [System.DBNull]` check when extracting department scope from RBAC context.

### What's Functional (Steps 1-6)

1. **Select Environment** -- Cards for TEST, STAGE, PROD loaded from `Tools.ServerConfig`. Environment-specific accent colors. STAGE and PROD temporarily locked with "Coming Soon" label (controlled by JS `locked` variable in `renderEnvironments`).
2. **Select Entity Type** -- Grid of available entities filtered by `is_active = 1` and RBAC tier/department. Searchable. Admin sees all active; department users see only AccessConfig-granted entities. Template count preview shown in right column when entity is selected.
3. **Upload File** -- Drag-and-drop or browse. CSV, TXT, XLSX, XLS supported via client-side parsing (SheetJS for Excel). Preview renders inside the drop zone replacing the upload prompt. Row count warning above 250K.
4. **Map Columns** -- Identifier field (consumer or account agency ID) must be selected first -- mapping panels are disabled with red border highlight until identifier is chosen. Once selected, identifier border turns green and two-column layout (Source | BDL Fields) activates with click-to-pair and drag-and-drop. Mapped pairs displayed in a spanning section below. Display names shown when populated. Templates can be loaded from the right column to pre-populate mappings. "Save Current Mapping as Template" button available when mappings exist.
5. **Validate** -- Two-phase: stage (one-time) then validate (repeatable with cascading re-validate).
   - **Stage:** Reads full file, creates `Staging.BDL_{entity}_{user}_{timestamp}` table. Supports `drop_existing` parameter for re-staging when mapping changes on back navigation.
   - **Validate:** Accordion-style issue cards. Actionable issues (required empty, invalid lookup) shown as collapsed cards -- click to expand and resolve. One card expandable at a time. Required empty: fill or skip triggers immediate re-validate. Lookup invalid: all unique values resolved per element, then auto re-validate. Cascading effect: skipping rows for one field removes those rows from subsequent lookup/required checks.
   - Informational warnings (max length, data type) shown in separate collapsible section with no action controls.
   - Next button muted/gray when issues exist, colored blue when validation passes.
   - **Re-validate button** retained at bottom as manual sanity check.
   - **Staging cleanup:** Banner on page load if tables older than 48 hours found. One-click cleanup drops them.
6. **Review & Execute** -- Summary display showing environment, entity type, source file, row count, mapped fields, and staging table. Collapsible column mapping reference. Collapsible XML preview with syntax highlighting. Execute button with PROD warning. Progress visualization. Success/failure result cards.

### End-to-End Test Results

**April 3, 2026 (TEST):**
- **Test 1 (Dirk):** 24-row PHONE file -> staged, validated, XML built, registered with DM (fileRegistryId 304146), import triggered, DM processed successfully. All 24 phone records confirmed in crs5_oltp.
- **Test 2 (Brandon):** ~5000-row PHONE file with ~1100 rows missing phone numbers -> staged, validated with skip, quality score filled, import submitted successfully.

**April 4, 2026 (PROD):**
- **Test 3 (Dirk):** PHONE BDL import into PRODUCTION -- 100% success. First production import via xFACts.

---

## Architecture Decisions (Resolved)

### Template System
- `Tools.BDL_ImportTemplate` stores reusable column mappings as JSON per entity type
- Templates visible to all users; creator or admin can update/delete (soft delete via `is_active = 0`)
- Template preview via shared slideout panel (`slide-panel` from engine-events.css) showing field-by-field matching against current file
- Case-insensitive header matching when applying -- only columns present in both template and file are mapped; unmatched fields left for manual pairing
- Match count displayed in template list and slideout preview ("3 of 5 fields match your file")
- Save modal with name, optional description, and mapping preview

### Back Navigation and Staging Reuse
- Column mapping preserved on back navigation to Step 4 (not reset to empty)
- Identifier dropdown selection restored on re-render
- On Step 4 -> Step 5 transition: if mapping unchanged from what was staged, existing staging table is reused (no re-stage). If mapping changed, old staging table is dropped via `drop_existing` parameter and new one created. Prevents accumulation of orphan staging tables.

### Cascading Validation
- Validation issues presented as accordion cards -- one expandable at a time
- Required empty and lookup invalid are actionable (fill/replace/skip controls)
- Max length and data type are informational only (no action controls)
- After each fill or skip action on a required empty field, auto re-validate fires immediately
- After all unique values for a lookup invalid field are resolved (replaced or skipped), auto re-validate fires
- Cascading effect: skipping rows with empty phone numbers removes those same rows from phone type and phone status lookup checks
- User interaction disabled during re-validate cycle to prevent race conditions

### Identifier Field Gating
- Mapping panels (source columns, BDL fields, mapped pairs) are disabled and dimmed until the identifier column is selected
- Identifier section has red border when unselected, green border when confirmed
- Centered overlay message "Select the identifier column above to begin mapping" shown on dimmed panels
- Click, drag, and drop interactions blocked via `isMappingDisabled()` guard on all interaction handlers

### Guide Panel
- Compact tip panel in upper right column -- no step circles (redundant with stepper bar), no hide/show toggle
- Content updates automatically based on current step
- Fixed height, always visible

### Server Configuration
- `tools_enabled` on ServerRegistry = "this server participates in Tools operations" (master switch)
- `Tools.ServerConfig` = per-environment operational config (API URLs, dmfs paths, pipeline folder names, `db_instance` for database targeting)
- `db_instance` stores the database server/listener per environment (AVG-PROD-LSNR, AVG-STAGE-LSNR, DM-TEST-APP)
- Environment selection is UI-driven per import, no GlobalConfig default

### DM API Authentication
- Credentials stored in `dbo.Credentials` under `ServiceName = 'DM_REST_API'` with three config keys: `Username`, `Password`, `AuthHeader`
- Two-tier encryption: master passphrase -> service passphrase -> credential values
- `AuthHeader` stores the complete `Basic <base64>` string as-is from Matt's legacy toolkit
- **Extra character note:** The base64-decoded AuthHeader value has one extra trailing character compared to the stored password. Always use `AuthHeader` directly.

### XML Construction
- XML built entirely from catalog data -- no XSD files needed at runtime
- Mirrors Matt's VBA XML structure exactly
- File extension is `.txt` (not `.xml`) -- matches Matt's convention
- File written with BOM-less UTF-8 encoding

### Access Control (Three Layers)
1. **RBAC page access** -- `RBAC_PermissionMapping` controls who can see the page
2. **Entity access** -- `Tools.AccessConfig` controls which BDL entity types a department can use. Admin tier bypasses.
3. **Field access** -- `Tools.AccessFieldConfig` controls which fields a department can see/use. Strict whitelist. Admin tier bypasses.

### Staging Architecture
- Tables created in `Staging` schema -- not registered in xFACts platform
- Table naming: `Staging.BDL_{entity}_{username}_{timestamp}`
- All columns stored as VARCHAR regardless of BDL data type
- Bulk INSERT in batches of 500 rows
- Staging is one-time per import; validation is repeatable against existing table
- Re-staging on mapping change drops old table atomically via `drop_existing` parameter on stage endpoint

### Import Lifecycle
- Status progression: BUILDING -> REGISTERED -> SUBMITTED / FAILED
- Failed imports require a new file with a new filename
- Column mapping captured as JSON in `BDL_ImportLog.column_mapping` for audit trail
- `template_id` column links to `BDL_ImportTemplate` when a template-based import is executed

### RBAC Middleware: Department-Scoped Roles on Shared Pages
- **Problem:** Department-scoped roles were silently ignored on non-departmental pages like `/bdl-import`.
- **Fix:** Modified scope check in `Get-UserPageTier` -- explicit permission rows are always honored regardless of department scope.
- **Impact:** Platform-wide.

### Identifier Handling
- Consumer-level imports use `cnsmr_idntfr_agncy_id` as the identifier
- Account-level imports use `cnsmr_accnt_idntfr_agncy_id`
- Other identifier fields hidden via `is_visible = 0` -- only agncy_id works reliably per Matt
- Identifier must be selected before column mapping is enabled (gating behavior)

---

## Matt's Answers (From Session)

*(Unchanged -- see prior version for full Q&A history)*

---

## DM API Integration

*(Unchanged -- see prior version for server routing, API calls, status progression, and XML structure)*

---

## Implemented CC API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/bdl-import/environments` | Available environments from ServerConfig |
| GET | `/api/bdl-import/entities` | Available entity types (RBAC + is_active filtered) |
| GET | `/api/bdl-import/entity-fields?entity_type=X` | BDL fields for an entity (admin: all visible; dept: AccessFieldConfig whitelist) |
| POST | `/api/bdl-import/stage` | Create staging table and insert all rows. Optional `drop_existing` drops prior table. |
| POST | `/api/bdl-import/validate` | Read staging table + fetch lookups from DM (repeatable) |
| POST | `/api/bdl-import/replace-values` | Mass-replace values in staging table column (handles empty->value) |
| POST | `/api/bdl-import/skip-rows` | Mark rows as skipped in staging table (handles empty match) |
| GET | `/api/bdl-import/staging-cleanup` | Check for expired staging tables (>48 hours) |
| POST | `/api/bdl-import/staging-cleanup` | Drop expired staging tables |
| GET | `/api/bdl-import/history` | Recent import history from BDL_ImportLog |
| POST | `/api/bdl-import/build-preview` | Build XML and return for preview (no file write or API calls) |
| POST | `/api/bdl-import/execute` | Full pipeline: build XML -> write to dmfs -> register -> trigger import |
| GET | `/api/bdl-import/templates?entity_type=X` | List saved templates for an entity type |
| POST | `/api/bdl-import/templates` | Save a new template (duplicate name check) |
| PUT | `/api/bdl-import/templates/:id` | Update a template (creator or admin only) |
| DELETE | `/api/bdl-import/templates/:id` | Deactivate a template (creator or admin only) |

---

## Next Steps

### Immediate (Next Session)

1. **`communication_reference_id_txt` header element** -- Verify with Matt whether this is required by DM or just informational. Matt's VBA includes it in some BDL functions (PostPhnUpdts, PostAddrUpdts, PostAccntUpdts, PostCnsmrUpdts) but not others (PostAccntTags, PostCnsmrTags).

2. **Step guide text refinement** -- Update the right-column guidance text for each step based on user feedback. Content is in `BDLImport.ps1` HTML.

3. **Template UX refinement** -- Gather user feedback on the template workflow (browse, preview, apply, save). Iterate on visual design and interaction patterns as needed.

### Phase 2

- Import history view on the BDL Import page
- Admin UI for AccessFieldConfig management
- Admin UI for `is_active` toggle on format tables
- `display_name` enrichment across additional entity elements
- Staging table resume/review capability
- Post-import staging table viewer

### Future Enhancements

- **Catalog field defaults and guidance** -- Add `default_value VARCHAR(100)` and `input_guidance VARCHAR(200)` columns to `Catalog_BDLElementRegistry`. `default_value` pre-populates the fill input (user-selectable, not auto-applied). `input_guidance` provides hint text near input controls. Requires DDL change and Matt review for population.
- Payment Import pipeline (separate XML schema and API flow)
- Scheduled Job Triggers (configuration-driven panel)
- Consumer CRUD Operations (individual UI forms)
- CDL Import pipeline
- DM Monitoring Dashboard widgets
- New Business Import pipeline

---

## Catalog Table Reference

*(Unchanged -- see prior version for table structures, enrichment sources, and "Three Required Columns" disambiguation)*

---

## Database Object Inventory

### Tools.Operations Component
| Object | Type | Description |
|--------|------|-------------|
| ServerConfig | Table | Per-environment DM server configuration (incl. db_instance) |
| AccessConfig | Table | Department-scoped tool/entity access control |
| AccessFieldConfig | Table | Field-level whitelist, child of AccessConfig |
| BDL_ImportLog | Table | Import execution audit trail |
| BDL_ImportTemplate | Table | Saved column mapping templates (incl. description column) |
| BDLImport.ps1 | Route | BDL Import CC page route (two-column layout) |
| BDLImport-API.ps1 | API | BDL Import CC API endpoints (incl. template CRUD) |
| bdl-import.js | JavaScript | BDL Import CC client-side logic |
| bdl-import.css | CSS | BDL Import CC styles |

### ControlCenter.Shared Component
| Object | Type | Description |
|--------|------|-------------|
| xFACts-Helpers.psm1 | Module | Shared helper functions (incl. Invoke-XFActsNonQuery, Build-BDLXml, Get-ServiceCredentials) |

### DeptOps.ApplicationsIntegration Component
| Object | Type | Description |
|--------|------|-------------|
| ApplicationsIntegration.ps1 | Route | Apps/Int CC page route |
| applications-integration.css | CSS | Apps/Int CC styles |

---

## Outstanding Items for Object_Registry and System_Metadata

**Object_Registry entries completed this session:**
- `BDL_ImportTemplate` table -- registered with Object_Metadata baselines, column descriptions, data flow, design notes, and relationship notes

**System_Metadata version bumps needed (end of session):**
- **Module: Tools -> Component: Tools.Operations** -- `BDL_ImportTemplate` table with description column, template CRUD API endpoints, `drop_existing` staging support
- **Module: ControlCenter -> Component: ControlCenter.BDLImport** (or Tools.Operations if BDL Import CC files are under that component) -- Cascading validation redesign, accordion cards, back button mapping preservation, guide panel simplification, template UI with slideout preview, identifier field gating, Next button color logic, shared engine-events.css integration

# BDL Import Module — Working Document

**Status:** In development — Steps 1-6 functional, end-to-end tested on TEST  
**Audience:** Dirk, Matt, Brandon, Claude  
**Last Updated:** April 3, 2026  
**Replaces:** `BDL_Import_Module_Design.md`, `BDL_Catalog_Reload_Instructions.md`, `xFACts_Questions_For_Matt.md`

---

## Overview

A Control Center page (`/bdl-import`) that allows authorized users to upload a vendor data file, map its columns to BDL fields via click-to-pair or drag-and-drop, validate the data against DM reference tables, preview the generated XML, and trigger a BDL import into Debt Manager. Accessible via card links from the Applications & Integration page (IT team) and the Business Intelligence page (BI team). RBAC controls page access; `Tools.AccessConfig` controls entity-level access per department; `Tools.AccessFieldConfig` controls field-level access per department (strict whitelist).

---

## Current State

### What's Built and Deployed

**Database infrastructure (Tools schema):**
- `tools_enabled` column on `dbo.ServerRegistry` — master switch for Tools server participation (7 app servers enabled)
- `Tools.ServerConfig` — 3 rows (one per environment) with API URLs, dmfs paths, `db_instance`, and pipeline folder names for environment-specific targeting
- `Tools.AccessConfig` — department-scoped entity access control (BI seeded with PHONE only)
- `Tools.AccessFieldConfig` — field-level whitelist, child of AccessConfig. Strict whitelist: no child rows = zero field access. Admin tier bypasses entirely. BI seeded with `is_import_required` PHONE fields.
- `Tools.BDL_ImportLog` — import execution audit trail with lifecycle status tracking, `column_mapping` JSON, `value_changes` column for replacement audit, and `file_registry_id` from DM API
- `Tools.BDL_ImportTemplate` — saved column mapping templates for vendor-specific file layouts (table created, endpoints/UI not yet built)
- `Staging` schema — created for temporary import staging tables (not registered in xFACts platform, invisible to documentation pipeline)
- `AVG-STAGE-LSNR` added to `dbo.ServerRegistry` (AG_LISTENER, STAGE, DMSTAGEAG, is_active=0)
- `Tools.Operations` component — registered and baselined

**DM API Integration (fully operational):**
- `dbo.CredentialServices` row for `DM_REST_API`
- `dbo.Credentials` rows for Username, Password, and AuthHeader (two-tier encrypted)
- Auth pattern mirrors Matt's legacy VBA toolkit exactly: `Authorization` header passed through as-is from stored `AuthHeader` value, `Content-Type: application/vnd.fico.dm.v1+json`
- API flow: POST `/fileregistry` (register file, extract `data.fileRegistryId` from response) → POST `/fileregistry/{id}/bdlimport` (trigger import)
- File write uses BOM-less UTF-8 encoding (`New-Object System.Text.UTF8Encoding($false)`) — DM's XML parser rejects BOM

**Catalog enrichment:**
- `format_id` integer FK added to `Catalog_BDLElementRegistry` and `Catalog_CDLElementRegistry` (replaces composite FK)
- `is_visible` and `is_import_required` columns on both element registry tables
- `display_name VARCHAR(100)` on both element registry tables — human-readable field names for mapping UI
- `is_active BIT` on both format registry tables — controls entity availability
- Field descriptions enriched from SchemaSpy DM database column comments (682 verified descriptions)
- `is_not_nullifiable` and `is_primary_id` populated from Excel interface definition
- `table_column` and `lookup_table` populated from Excel interface definition
- `is_visible = 0` set on unreliable identifier fields and primary ID fields
- `is_import_required` flags set by Matt for PHONE entity
- All `spec_version` hardcoded filters removed from API queries — catalog data filtered by `is_active` and `is_visible` only

**Shared helpers:**
- `Invoke-XFActsNonQuery` added to `xFACts-Helpers.psm1` — ExecuteNonQuery() for DDL and DML operations against xFACts database
- `Build-BDLXml` added to `xFACts-Helpers.psm1` — constructs BDL XML from staging table data and catalog metadata. Mirrors Matt's VBA XML structure exactly: `<dm_data>` root with FICO namespace, header block (sender, target, batch_id, operational_transaction_type, total_count, creation_data), wrapper element from catalog, entity elements with `seq_no` and `type` attributes
- `Get-ServiceCredentials` in `xFACts-Helpers.psm1` — two-tier decryption for DM API credentials

**Control Center pages:**
- `BDLImport.ps1` / `BDLImport-API.ps1` / `bdl-import.js` / `bdl-import.css` — BDL Import wizard page
- Two-column layout: 65% left (stepper bar + action panels) / 35% right (step guide with numbered steps and guidance text)
- "Hide Guide" toggle collapses the right column
- `ApplicationsIntegration.ps1` / `applications-integration.css` — Apps/Int departmental page under `DeptOps.ApplicationsIntegration`
- BI page updated: BDL Import card now links to `/bdl-import`
- SheetJS `xlsx.full.min.js` v0.20.3 hosted locally for client-side Excel parsing

**RBAC:**
- BDL Import page: Admin (wildcard), PowerUser/StandardUser = admin tier, ReadOnly = view, DeptStaff/DeptManager = operate
- Admin tier on BDL Import = unrestricted entity and field access (bypasses AccessConfig and AccessFieldConfig)
- Operate tier on BDL Import = entities filtered by AccessConfig, fields filtered by AccessFieldConfig (strict whitelist)
- **Middleware fix applied:** `Get-UserPageTier` in `xFACts-Helpers.psm1` updated so department-scoped roles are honored on non-departmental pages when an explicit permission row exists.
- **DBNull handling:** API endpoints use `-isnot [System.DBNull]` check when extracting department scope from RBAC context.

### What's Functional (Steps 1-6)

1. **Select Environment** — Cards for TEST, STAGE, PROD loaded from `Tools.ServerConfig`. Environment-specific accent colors. STAGE and PROD temporarily locked with "Coming Soon" label (controlled by JS `locked` variable in `renderEnvironments`).
2. **Select Entity Type** — Grid of available entities filtered by `is_active = 1` and RBAC tier/department. Searchable. Admin sees all active; department users see only AccessConfig-granted entities.
3. **Upload File** — Drag-and-drop or browse. CSV, TXT, XLSX, XLS supported via client-side parsing (SheetJS for Excel). Preview renders inside the drop zone replacing the upload prompt. Row count warning above 250K.
4. **Map Columns** — Two-column layout (Source | BDL Fields) with click-to-pair and drag-and-drop. Mapped pairs displayed in a spanning section below. Display names shown when populated (friendly name primary, element_name secondary in monospace). Identifier field auto-mapped based on entity level (consumer vs account). Unmapped `is_import_required` fields warned with note that they'll be added to staging.
5. **Validate** — Two-phase: stage (one-time) then validate (repeatable loop).
   - **Stage:** Reads full file, creates `Staging.BDL_{entity}_{user}_{timestamp}` table with mapped columns, unmapped columns (`_unmapped` suffix), and auto-added `is_import_required` fields not in the file. Bulk INSERT in batches of 500.
   - **Validate:** Reads non-skipped rows from staging table. Fetches lookup values from DM via `Invoke-CRS5ReadQuery -TargetInstance $dbInstance`. Lookup discovery via `INFORMATION_SCHEMA.COLUMNS` finds `_val_txt` and `_actv_flg` columns dynamically. Client-side validation checks: required empty, max length, data type (int/long/short/decimal/boolean), lookup membership.
   - **Required empty = hard block** for `is_not_nullifiable` fields (Fill only). **Required empty = warning with Skip option** for non-nullifiable required fields (Fill + Skip). This distinction uses the existing `is_not_nullifiable` flag on `Catalog_BDLElementRegistry`.
   - **Lookup/length/type = warnings.** Can proceed. Invalid lookup values show replace dropdown + skip option per unique value.
   - **Re-validate** reads from the existing staging table — no new table created. Replacements and fills are already applied.
   - **Staging cleanup:** Banner on page load if tables older than 48 hours found. One-click cleanup drops them.
6. **Review & Execute** — Summary display showing environment, entity type, source file, row count, mapped fields, and staging table. Collapsible column mapping reference. Collapsible XML preview with syntax highlighting (VS Code color scheme). Execute button with PROD warning. Progress visualization (Building XML → Writing File → Registering with DM → Triggering Import). Success/failure result cards with file registry ID and log ID. `BDL_ImportLog` row tracks full lifecycle with status progression BUILDING → REGISTERED → SUBMITTED (or FAILED at any stage with error capture).

### End-to-End Test Results (April 3, 2026)

Two successful BDL imports completed on DM-TEST-APP:
- **Test 1 (Dirk):** 24-row PHONE file → staged, validated, XML built, file written to `\\dm-test-app\e$\dmfs\import\bdl\`, registered with DM (fileRegistryId 304146), import triggered, DM processed successfully (file_stts_cd = 5). All 24 phone records confirmed in crs5_oltp.
- **Test 2 (Brandon):** ~5000-row PHONE file with ~1100 rows missing phone numbers → staged, validated with skip on empty phone numbers, quality score filled, import submitted successfully. Data loaded for matched records.

**Issues found and resolved during testing:**
- UTF-8 BOM: `[System.Text.Encoding]::UTF8` writes BOM causing "Content is not allowed in prolog" XML parse error. Fixed with `New-Object System.Text.UTF8Encoding($false)`.
- DM response structure: `fileRegistryId` nested under `response.data.fileRegistryId`, not at top level. Fixed extraction logic.
- Pode runspace isolation: `Build-BDLXml` function defined in route file not visible in Pode scriptblocks. Moved to `xFACts-Helpers.psm1` and added to `Export-ModuleMember`.
- Required field skip logic: Empty phone numbers should allow skip (row is meaningless), but empty quality scores should not (row is valid but incomplete). Resolved using existing `is_not_nullifiable` flag — `is_not_nullifiable = 1` means fill only, `is_not_nullifiable = 0` means fill + skip.

---

## Architecture Decisions (Resolved)

### Server Configuration
- `tools_enabled` on ServerRegistry = "this server participates in Tools operations" (master switch)
- `Tools.ServerConfig` = per-environment operational config (API URLs, dmfs paths, pipeline folder names, `db_instance` for database targeting)
- `db_instance` stores the database server/listener per environment (AVG-PROD-LSNR, AVG-STAGE-LSNR, DM-TEST-APP) — used by `Invoke-CRS5ReadQuery` for lookup validation
- File target and API target may be different servers in multi-node environments
- Path construction: `dmfs_base_path + '\' + dmfs_bdl_folder + '\'` — fully data-driven
- Environment selection is UI-driven per import, no GlobalConfig default

### DM API Authentication
- Credentials stored in `dbo.Credentials` under `ServiceName = 'DM_REST_API'` with three config keys: `Username`, `Password`, `AuthHeader`
- Two-tier encryption: master passphrase → service passphrase → credential values
- `AuthHeader` stores the complete `Basic <base64>` string as-is from Matt's legacy toolkit — passed through without transformation
- **Extra character note:** The base64-decoded AuthHeader value has one extra trailing character compared to the stored password. The AuthHeader value is known to work (verified via Postman). Always use `AuthHeader` directly rather than constructing from Username/Password.
- Auth headers mirror Matt's VBA exactly: `Authorization: {AuthHeader}`, `Content-Type: application/vnd.fico.dm.v1+json`
- Credentials retrieved via `Get-ServiceCredentials -ServiceName 'DM_REST_API'` at execute time (no caching)

### XML Construction
- XML built entirely from catalog data (`Catalog_BDLFormatRegistry` + `Catalog_BDLElementRegistry`) — no XSD files needed at runtime
- Root element: `<dm_data xmlns="http://www.fico.com/xml/debtmanager/data/v1_0">`
- Header block: `sender_id_txt` (Organization), `target_id_txt` (FAC Debt Manager), `batch_id_txt`, `operational_transaction_type`, `total_count`, `creation_data`
- Wrapper element determined from catalog: query finds which wrapper type contains the entity's data type
- Entity elements include `seq_no` (1-based sequential) and `type` (entity_type value) attributes
- Empty/null field values excluded from XML (only non-empty values emitted)
- XML values are XML-escaped (& < > " ')
- File extension is `.txt` (not `.xml`) — matches Matt's convention
- Filename convention: `xFACts_{entity}_{username}_{yyyyMMdd_HHmmss}.txt`
- File written with BOM-less UTF-8 encoding

### Access Control (Three Layers)
1. **RBAC page access** — `RBAC_PermissionMapping` controls who can see the page at all
2. **Entity access** — `Tools.AccessConfig` controls which BDL entity types a department can use. `tool_type = 'BDL'`, `item_key = entity_type`, `department_scope`. Admin tier bypasses.
3. **Field access** — `Tools.AccessFieldConfig` controls which fields within a granted entity a department can see/use. Strict whitelist: no child rows = zero field access. Default grant policy: seed with `is_import_required` fields only, expand on request (principle of least privilege). Admin tier bypasses.

### Catalog Filtering
- `is_active` on format tables = "is this entity available for use" (deactivation cascades through query filtering)
- `is_visible` on element tables = "should users see this field" (hides unreliable identifiers, primary IDs)
- `is_import_required` on element tables = "must this field have a value for the BDL to succeed"
- `is_not_nullifiable` on element tables = "cannot be cleared on update" — **repurposed for validation UI**: controls whether Skip button appears on required empty fields. `is_not_nullifiable = 1` → fill only. `is_not_nullifiable = 0` → fill + skip.
- `spec_version` retained as informational column only — not used as a filter anywhere
- `display_name` on element tables = human-readable field name for mapping UI. Falls back to `element_name` when NULL.

### Staging Architecture
- Tables created in `Staging` schema — not registered in xFACts platform, invisible to documentation pipeline
- Table naming: `Staging.BDL_{entity}_{username}_{timestamp}`
- Column structure: `_row_number` (IDENTITY), `_skip` (BIT), mapped columns (element names with catalog-derived VARCHAR types), unmapped columns (`{name}_unmapped` VARCHAR(MAX)), auto-added `is_import_required` fields as empty columns
- All columns stored as VARCHAR regardless of BDL data type — validation checks type, staging stores as string
- Bulk INSERT in batches of 500 rows
- Staging is one-time per import; validation is repeatable against existing table
- Expired tables (>48 hours) cleaned up on page load via banner prompt

### Validation Flow
- Stage and validate are separated: stage creates the table once, validate reads from it repeatedly
- Lookup values fetched from DM via `Invoke-CRS5ReadQuery -TargetInstance $dbInstance` — no cross-server JOINs
- Lookup discovery: `INFORMATION_SCHEMA.COLUMNS` finds `_val_txt` and `_actv_flg` columns dynamically per lookup table
- `is_import_required` is the ONLY flag for "required" — `is_not_nullifiable` controls skip eligibility, not required status
- Required empty fields with `is_not_nullifiable = 1` = Fill only (hard block)
- Required empty fields with `is_not_nullifiable = 0` = Fill + Skip (can exclude rows)
- All other issues (lookup, length, type) = warnings (can proceed)
- Value replacements and fills update the staging table directly; re-validate reads the corrected data

### Import Lifecycle
- Status progression: BUILDING → REGISTERED → SUBMITTED / FAILED
- BUILDING: XML constructed, ImportLog row created, file written to dmfs
- REGISTERED: File registered with DM via POST /fileregistry, file_registry_id captured
- SUBMITTED: BDL import triggered via POST /fileregistry/{id}/bdlimport
- FAILED: Error at any stage — error_message captured, completed_dttm set
- Failed imports require a new file with a new filename
- Column mapping captured as JSON in `BDL_ImportLog.column_mapping` for audit trail
- `value_changes` column captures replacement/fill actions applied during validation
- `template_id` column reserved for future template FK

### RBAC Middleware: Department-Scoped Roles on Shared Pages
- **Problem:** Department-scoped roles were silently ignored on non-departmental pages like `/bdl-import`.
- **Fix:** Modified scope check in `Get-UserPageTier` — explicit permission rows are always honored regardless of department scope.
- **Impact:** Platform-wide. Any future shared page works correctly with explicit permission rows.

### Identifier Handling
- Consumer-level imports use `cnsmr_idntfr_agncy_id` as the identifier (auto-mapped in UI)
- Account-level imports use `cnsmr_accnt_idntfr_agncy_id`
- Other identifier fields hidden via `is_visible = 0` — only agncy_id works reliably per Matt
- Identifier column selection is separate from the field mapping

---

## Matt's Answers (From Session)

### Before Build (All Answered)

1. **DM API Credentials:** Confirmed. Matt's toolkit uses `APIDeets` table with `uName`, `pwd`, `auth` fields. Auth is Basic auth with a pre-built `Authorization` header. Token never expires. Credentials now stored in `dbo.Credentials` under `DM_REST_API` service. Verified working via Postman and end-to-end test.
2. **dmfs File Paths:** Confirmed correct. Paths now stored in `Tools.ServerConfig`. Service account has write access (confirmed via successful file write to `\\dm-test-app\e$\dmfs\import\bdl\`).
3. **First Entity Types:** Phone, Consumer Tags, Account Tags recommended. **PHONE entity fully configured and tested end-to-end.**
4. **Legacy Toolkit:** Unmapped functions are dead code from an earlier version.

### During Build (All Answered)

5. **Companion File Pattern:** Can be combined into single BDL file.
6. **Concurrent Imports:** Fine, but don't overwhelm DM.
7. **File Size / Row Limits:** Practical limit ~250K rows. Timeouts above 300-350K.
8. **Error Recovery:** New file with new name required.
9. **Catalog Data Quality:** Duplicate Case Tag/Case History are documentation issue.

### Key Learnings from Matt (April 1)

10. **`is_not_nullifiable` is NOT "required for import."** It means "cannot be included in nullify_fields during update operations." Completely different from import requirements. Only `is_import_required` should be used for required field checks.
11. **`cnsmr_phn_qlty_score_nmbr` is required by the XSD.** Without it, the BDL runs but silently does nothing — no insert, no update, no error. This is why `is_import_required` exists and why required fields are a hard block.

### Key Learning (April 3)

12. **`is_not_nullifiable` repurposed for validation UI skip logic.** Fields with `is_not_nullifiable = 1` that are also `is_import_required = 1` get Fill only (no Skip button). Fields with `is_not_nullifiable = 0` that are `is_import_required = 1` get both Fill and Skip. This maps correctly: quality score (not-nullifiable, must fill) vs phone number (nullifiable, can skip row). Confirmed by cross-referencing all PHONE entity fields.

---

## DM API Integration

### Server Routing
| Environment | File Target (dmfs) | API Target | DB Instance |
|-------------|-------------------|------------|-------------|
| TEST | DM-TEST-APP | DM-TEST-APP | DM-TEST-APP |
| STAGE | DM-STAGE-APP3 | DM-STAGE-APP | AVG-STAGE-LSNR |
| PROD | DM-PROD-APP3 | DM-PROD-APP | AVG-PROD-LSNR |

### API Calls (Two per import)

**Call 1: Register the file**
```
POST {api_base_url}/fileregistry
Content-Type: application/vnd.fico.dm.v1+json
Authorization: {AuthHeader from Credentials}
Body: { "fileName": "filename.txt", "fileType": "BDL_IMPORT" }
Response: { "status": "success", "data": { "fileRegistryId": NNN, ... } }
```

**Call 2: Trigger the import**
```
POST {api_base_url}/fileregistry/{file_registry_id}/bdlimport
Content-Type: application/vnd.fico.dm.v1+json
Authorization: {AuthHeader from Credentials}
Body: (empty)
```

### DM File Registry Status Progression
After registration, DM processes the file asynchronously: NEW (1) → UPDATING (2) → READY (3) → PROCESSING (4) → PROCESSED (5). If the file content is invalid (e.g., XML parse error), it goes directly to FAILED (6). The bdlimport trigger requires the file to be in READY status — in practice, DM reaches READY before the trigger call completes.

### XML Structure (Catalog-Driven)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<dm_data xmlns="http://www.fico.com/xml/debtmanager/data/v1_0">
  <header>
    <sender_id_txt>Organization</sender_id_txt>
    <target_id_txt>FAC Debt Manager</target_id_txt>
    <batch_id_txt>xFACts_PHONE_20260403_075939</batch_id_txt>
    <operational_transaction_type>CONSUMER</operational_transaction_type>
    <total_count>24</total_count>
    <creation_data>2026-04-03T07:59:00</creation_data>
    <custom_properties>
      <custom_property/>
    </custom_properties>
  </header>
  <operational_transaction_data>
    <consumer_operational_transaction_data>
      <cnsmr_phn seq_no="1" type="PHONE">
        <cnsmr_idntfr_agncy_id>80041479</cnsmr_idntfr_agncy_id>
        <cnsmr_phn_nmbr_txt>5551234567</cnsmr_phn_nmbr_txt>
        <cnsmr_phn_typ_val_txt>Home</cnsmr_phn_typ_val_txt>
      </cnsmr_phn>
    </consumer_operational_transaction_data>
  </operational_transaction_data>
</dm_data>
```

**Note:** Matt's VBA also includes `<communication_reference_id_txt>Organization</communication_reference_id_txt>` in the header for some entity types. Not yet confirmed whether this is required by DM or informational. Needs verification with Matt before adding.

---

## Implemented CC API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/bdl-import/environments` | Available environments from ServerConfig |
| GET | `/api/bdl-import/entities` | Available entity types (RBAC + is_active filtered) |
| GET | `/api/bdl-import/entity-fields?entity_type=X` | BDL fields for an entity (admin: all visible; dept: AccessFieldConfig whitelist) |
| POST | `/api/bdl-import/stage` | Create staging table and insert all rows (one-time) |
| POST | `/api/bdl-import/validate` | Read staging table + fetch lookups from DM (repeatable) |
| POST | `/api/bdl-import/replace-values` | Mass-replace values in staging table column (handles empty→value) |
| POST | `/api/bdl-import/skip-rows` | Mark rows as skipped in staging table (handles empty match) |
| GET | `/api/bdl-import/staging-cleanup` | Check for expired staging tables (>48 hours) |
| POST | `/api/bdl-import/staging-cleanup` | Drop expired staging tables |
| GET | `/api/bdl-import/history` | Recent import history from BDL_ImportLog |
| POST | `/api/bdl-import/build-preview` | Build XML and return for preview (no file write or API calls) |
| POST | `/api/bdl-import/execute` | Full pipeline: build XML → write to dmfs → register → trigger import |

### Endpoints Still Needed

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/bdl-import/templates?entity_type=X` | List saved templates for an entity type |
| POST | `/api/bdl-import/templates` | Save a new template |
| PUT | `/api/bdl-import/templates/{id}` | Update a template (creator only) |
| DELETE | `/api/bdl-import/templates/{id}` | Deactivate a template (creator only) |

---

## Next Steps

### Immediate (Next Session)

1. **Template save/recall** — `Tools.BDL_ImportTemplate` table is created. Build API endpoints (list, save, update, delete). Build UI: template selection section in right column with mapping preview, "Save as Template" button on Step 4. Templates are entity-type specific, visible to all users. Creator can update own template; others save as new.

2. **Guide panel redesign** — Remove numbered step list (1-6 circles) from right column. Keep only text guidance in a compact fixed-height area. Move "Hide Guide" checkbox into guide panel header. Frees space for template section below.

3. **Back button mapping preservation** — Currently going back to Step 4 resets `columnMapping = {}`. Fix: only initialize columnMapping if it doesn't already exist. Preserve mapping state on back navigation.

4. **Cascading validation after skip/fill** — After a skip or fill action, auto re-validate against the staging table. Skipped rows (`_skip = 1`) are already excluded from validation queries. This prevents showing issues for rows that have already been excluded (e.g., Brandon's 1100 rows with empty phone numbers also showing as problems for phone type and phone status after being skipped).

5. **`communication_reference_id_txt` header element** — Verify with Matt whether this is required by DM or just informational. Matt's VBA includes it in some BDL functions (PostPhnUpdts, PostAddrUpdts, PostAccntUpdts, PostCnsmrUpdts) but not others (PostAccntTags, PostCnsmrTags).

6. **Manifest segmentation** — Split the GitHub manifest into a master index file (with links to sub-manifests) plus category-specific sub-manifests (ControlCenter, Documentation, PowerShell, WorkingFiles). The master manifest provides cascading access — fetching the master yields sub-manifest URLs, fetching sub-manifests yields file URLs. Eliminates truncation issues from the single large manifest. Requires update to `Publish-GitHubRepository.ps1`.

### Phase 2

- Import history view on the BDL Import page
- Admin UI for AccessFieldConfig management
- Admin UI for `is_active` toggle on format tables
- `display_name` enrichment across additional entity elements
- Staging table resume/review capability — detect existing staging tables for the current user, offer to resume from where a previous attempt left off
- Post-import staging table viewer — display staging table contents in a friendly format for reviewing what was sent to DM vs what actually went in

### Future Phases (from Legacy Toolkit Migration)

- Payment Import pipeline (separate XML schema and API flow)
- Scheduled Job Triggers (configuration-driven panel)
- Consumer CRUD Operations (individual UI forms)
- CDL Import pipeline
- DM Monitoring Dashboard widgets
- New Business Import pipeline

---

## Catalog Table Reference

### Tools.Catalog_BDLFormatRegistry
One row per BDL entity type. Parent table. Key columns: `format_id` (PK), `entity_type`, `type_name`, `folder`, `element_count`, `has_nullify_fields`, `is_active`.

### Tools.Catalog_BDLElementRegistry
One row per element within each entity type. Child table via `format_id` FK. Key columns: `element_name`, `display_name`, `data_type`, `max_length`, `table_column`, `lookup_table`, `is_not_nullifiable`, `is_primary_id`, `is_visible`, `is_import_required`, `field_description`.

### Enrichment Sources
- **XSD schema definitions:** `element_name`, `data_type`, `is_required`, `max_length`, `sort_order`
- **Excel interface definition:** `table_column`, `lookup_table`, `is_not_nullifiable`, `is_primary_id`, `field_description` (partial)
- **SchemaSpy DM database:** `field_description` (authoritative — 682 verified descriptions)
- **Manual curation:** `is_visible`, `is_import_required` (populated with Matt during entity review), `display_name` (friendly field names for UI)

### Three "Required" Columns (Disambiguation)
- `is_required` — XSD `minOccurs`. Almost always 0. Not useful for import decisions.
- `is_not_nullifiable` — From Excel spec. Means "cannot be included in nullify_fields during update operations." **NOT the same as required for import.** Also repurposed for validation UI: controls whether Skip button appears on required empty fields.
- `is_import_required` — Practical requirement from operational experience. Set by Matt. Means "you must provide this field for the import to succeed." **This is the only flag used for required field validation and hard blocks.**

---

## Database Object Inventory

### Tools.Operations Component
| Object | Type | Description |
|--------|------|-------------|
| ServerConfig | Table | Per-environment DM server configuration (incl. db_instance) |
| AccessConfig | Table | Department-scoped tool/entity access control |
| AccessFieldConfig | Table | Field-level whitelist, child of AccessConfig |
| BDL_ImportLog | Table | Import execution audit trail |
| BDL_ImportTemplate | Table | Saved column mapping templates |
| BDLImport.ps1 | Route | BDL Import CC page route (two-column layout) |
| BDLImport-API.ps1 | API | BDL Import CC API endpoints |
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

### Credential Infrastructure
| Object | Location | Description |
|--------|----------|-------------|
| DM_REST_API | dbo.CredentialServices | Service registration for DM REST API |
| Username | dbo.Credentials | DM API username (apiuser), encrypted |
| Password | dbo.Credentials | DM API password, encrypted |
| AuthHeader | dbo.Credentials | Complete Basic auth header string, encrypted |

---

## Outstanding Items for Object_Registry and System_Metadata

The following registrations and version bumps need to be recorded (deferred to end of template/UI session):

**Object_Registry entries needed:**
- `Build-BDLXml` function in xFACts-Helpers.psm1 (already registered as part of the module, but component pointer may need update)
- `BDL_ImportTemplate` table in Tools schema

**System_Metadata version bumps needed:**
- `Tools.Operations` — Step 6 execute endpoint, build-preview endpoint, BDL_ImportTemplate DDL, template endpoints (when built)
- `ControlCenter.Shared` — Build-BDLXml function added to helpers module

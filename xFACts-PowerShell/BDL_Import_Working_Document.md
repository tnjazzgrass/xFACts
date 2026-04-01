# BDL Import Module — Working Document

**Status:** In development — Steps 1-5 functional, Step 6 not started  
**Audience:** Dirk, Matt, Claude  
**Last Updated:** April 1, 2026  
**Replaces:** `BDL_Import_Module_Design.md`, `BDL_Catalog_Reload_Instructions.md`, `xFACts_Questions_For_Matt.md`

---

## Overview

A Control Center page (`/bdl-import`) that allows authorized users to upload a vendor data file, map its columns to BDL fields via click-to-pair or drag-and-drop, validate the data against DM reference tables, and trigger a BDL import into Debt Manager. Accessible via card links from the Applications & Integration page (IT team) and the Business Intelligence page (BI team). RBAC controls page access; `Tools.AccessConfig` controls entity-level access per department; `Tools.AccessFieldConfig` controls field-level access per department (strict whitelist).

---

## Current State

### What's Built and Deployed

**Database infrastructure (Tools schema):**
- `tools_enabled` column on `dbo.ServerRegistry` — master switch for Tools server participation (7 app servers enabled)
- `Tools.ServerConfig` — 3 rows (one per environment) with API URLs, dmfs paths, and `db_instance` for environment-specific database targeting
- `Tools.AccessConfig` — department-scoped entity access control (BI seeded with PHONE only)
- `Tools.AccessFieldConfig` — field-level whitelist, child of AccessConfig. Strict whitelist: no child rows = zero field access. Admin tier bypasses entirely. BI seeded with `is_import_required` PHONE fields.
- `Tools.BDL_ImportLog` — import execution audit trail with lifecycle status tracking and `value_changes` column for replacement audit
- `Staging` schema — created for temporary import staging tables (not registered in xFACts platform, invisible to documentation pipeline)
- `AVG-STAGE-LSNR` added to `dbo.ServerRegistry` (AG_LISTENER, STAGE, DMSTAGEAG, is_active=0)
- `Tools.Operations` component — registered and baselined

**Catalog enrichment:**
- `format_id` integer FK added to `Catalog_BDLElementRegistry` and `Catalog_CDLElementRegistry` (replaces composite FK)
- `is_visible` and `is_import_required` columns on both element registry tables
- `display_name VARCHAR(100)` on both element registry tables — human-readable field names for mapping UI
- `is_active BIT` on both format registry tables — controls entity availability (replaces `is_visible`, renamed April 1)
- Field descriptions enriched from SchemaSpy DM database column comments (682 verified descriptions)
- `is_not_nullifiable` and `is_primary_id` populated from Excel interface definition
- `table_column` and `lookup_table` populated from Excel interface definition
- `is_visible = 0` set on unreliable identifier fields and primary ID fields
- `is_import_required` flags set by Matt for PHONE entity
- All `spec_version` hardcoded filters removed from API queries — catalog data filtered by `is_active` and `is_visible` only

**Shared helpers:**
- `Invoke-XFActsNonQuery` added to `xFACts-Helpers.psm1` — ExecuteNonQuery() for DDL and DML operations against xFACts database. Accepts Parameters hashtable and configurable TimeoutSeconds (default 30).

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

### What's Functional (Steps 1-5)

1. **Select Environment** — Cards for TEST, STAGE, PROD loaded from `Tools.ServerConfig`. Environment-specific accent colors.
2. **Select Entity Type** — Grid of available entities filtered by `is_active = 1` and RBAC tier/department. Searchable. Admin sees all active; department users see only AccessConfig-granted entities.
3. **Upload File** — Drag-and-drop or browse. CSV, TXT, XLSX, XLS supported via client-side parsing (SheetJS for Excel). Preview renders inside the drop zone replacing the upload prompt. Row count warning above 250K.
4. **Map Columns** — Two-column layout (Source | BDL Fields) with click-to-pair and drag-and-drop. Mapped pairs displayed in a spanning section below. Display names shown when populated (friendly name primary, element_name secondary in monospace). Identifier field auto-mapped based on entity level (consumer vs account). Unmapped `is_import_required` fields warned with note that they'll be added to staging.
5. **Validate** — Two-phase: stage (one-time) then validate (repeatable loop).
   - **Stage:** Reads full file, creates `Staging.BDL_{entity}_{user}_{timestamp}` table with mapped columns, unmapped columns (`_unmapped` suffix), and auto-added `is_import_required` fields not in the file. Bulk INSERT in batches of 500.
   - **Validate:** Reads non-skipped rows from staging table. Fetches lookup values from DM via `Invoke-CRS5ReadQuery -TargetInstance $dbInstance`. Lookup discovery via `INFORMATION_SCHEMA.COLUMNS` finds `_val_txt` and `_actv_flg` columns dynamically. Client-side validation checks: required empty, max length, data type (int/long/short/decimal/boolean), lookup membership.
   - **Required empty = hard block.** Must fill before proceeding. Lookup fields show dropdown, non-lookup fields show free-text input. No skip option on required fields.
   - **Lookup/length/type = warnings.** Can proceed. Invalid lookup values show replace dropdown + skip option per unique value.
   - **Re-validate** reads from the existing staging table — no new table created. Replacements and fills are already applied.
   - **Staging cleanup:** Banner on page load if tables older than 48 hours found. One-click cleanup drops them.

### What's Not Built Yet (Step 6)

6. **Review & Execute** — Summary display, XML construction from catalog + validated staging data, file write to dmfs, API calls to register and trigger import, BDL_ImportLog row creation.

---

## Architecture Decisions (Resolved)

### Server Configuration
- `tools_enabled` on ServerRegistry = "this server participates in Tools operations" (master switch)
- `Tools.ServerConfig` = per-environment operational config (API URLs, dmfs paths, pipeline folder names, `db_instance` for database targeting)
- `db_instance` stores the database server/listener per environment (AVG-PROD-LSNR, AVG-STAGE-LSNR, DM-TEST-APP) — used by `Invoke-CRS5ReadQuery` for lookup validation
- File target and API target may be different servers in multi-node environments
- Path construction: `dmfs_base_path + '\' + dmfs_bdl_folder + '\'` — fully data-driven
- Environment selection is UI-driven per import, no GlobalConfig default

### Access Control (Three Layers)
1. **RBAC page access** — `RBAC_PermissionMapping` controls who can see the page at all
2. **Entity access** — `Tools.AccessConfig` controls which BDL entity types a department can use. `tool_type = 'BDL'`, `item_key = entity_type`, `department_scope`. Admin tier bypasses.
3. **Field access** — `Tools.AccessFieldConfig` controls which fields within a granted entity a department can see/use. Strict whitelist: no child rows = zero field access. Default grant policy: seed with `is_import_required` fields only, expand on request (principle of least privilege). Admin tier bypasses.

### Catalog Filtering
- `is_active` on format tables = "is this entity available for use" (deactivation cascades through query filtering — AccessConfig rows become unreachable)
- `is_visible` on element tables = "should users see this field" (hides unreliable identifiers, primary IDs)
- `is_import_required` on element tables = "must this field have a value for the BDL to succeed" (practical requirement set by Matt)
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
- `is_import_required` is the ONLY flag for "required" — `is_not_nullifiable` is not used for required checks
- Required empty fields = hard block (Step 5 won't complete). All other issues = warnings (can proceed).
- Value replacements and fills update the staging table directly; re-validate reads the corrected data

### RBAC Middleware: Department-Scoped Roles on Shared Pages
- **Problem:** Department-scoped roles were silently ignored on non-departmental pages like `/bdl-import`.
- **Fix:** Modified scope check in `Get-UserPageTier` — explicit permission rows are always honored regardless of department scope. Wildcard grants still need scope filtering.
- **Impact:** Platform-wide. Any future shared page works correctly with explicit permission rows.

### Identifier Handling
- Consumer-level imports use `cnsmr_idntfr_agncy_id` as the identifier (auto-mapped in UI)
- Account-level imports use `cnsmr_accnt_idntfr_agncy_id`
- Other identifier fields hidden via `is_visible = 0` — only agncy_id works reliably per Matt
- Identifier column selection is separate from the field mapping

### Import Lifecycle
- Status progression: VALIDATING → BUILDING → REGISTERED → SUBMITTED → COMPLETED / FAILED
- Failed imports require a new file with a new filename
- Column mapping captured as JSON in `BDL_ImportLog.column_mapping` for audit trail
- `value_changes` column captures replacement/fill actions applied during validation
- `template_id` column reserved for future template FK

---

## Matt's Answers (From Session)

### Before Build (All Answered)

1. **DM API Credentials:** Not yet confirmed. Matt offered to provide. **Action: Still needs setup/verification.**
2. **dmfs File Paths:** Confirmed correct. Paths now stored in `Tools.ServerConfig`.
3. **First Entity Types:** Phone, Consumer Tags, Account Tags recommended. **Action: PHONE entity fully configured. Others TBD.**
4. **Legacy Toolkit:** Unmapped functions are dead code from an earlier version.

### During Build (All Answered)

5. **Companion File Pattern:** Can be combined into single BDL file.
6. **Concurrent Imports:** Fine, but don't overwhelm DM.
7. **File Size / Row Limits:** Practical limit ~250K rows. Timeouts above 300-350K.
8. **Error Recovery:** New file with new name required.
9. **Catalog Data Quality:** Duplicate Case Tag/Case History are documentation issue.

### Key Learnings from Matt (April 1)

10. **`is_not_nullifiable` is NOT "required for import."** It means "cannot be included in nullify_fields during update operations." Completely different from import requirements. Only `is_import_required` should be used for required field checks.
11. **`cnsmr_phn_qlty_score_nmbr` is required by the XSD.** Without it, the BDL runs but silently does nothing — no insert, no update, no error. Matt thought PHONE was broken for a year+ until this was discovered. This is why `is_import_required` exists and why required fields are a hard block.

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
Body: { fileName: "filename.xml", fileType: "BDL_IMPORT" }
Response: includes file_registry_id
```

**Call 2: Trigger the import**
```
POST {api_base_url}/fileregistry/{file_registry_id}/bdlimport
```

Authentication: DM JWT token flow. **Status: Credentials setup not yet confirmed.**

### XML Structure (Catalog-Driven)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<operational_transaction_data xmlns="http://www.fico.com/xml/debtmanager/data/v1_0">
  <consumer_operational_transaction_data>
    <cnsmr_phn type="PHONE">
      <cnsmr_idntfr_agncy_id>12345</cnsmr_idntfr_agncy_id>
      <cnsmr_phn_nmbr_txt>5551234567</cnsmr_phn_nmbr_txt>
      <cnsmr_phn_typ_val_txt>CELL</cnsmr_phn_typ_val_txt>
    </cnsmr_phn>
  </consumer_operational_transaction_data>
</operational_transaction_data>
```

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

### Endpoints Still Needed

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/bdl-import/execute` | Build XML, register, trigger import |
| GET | `/api/bdl-import/templates` | List saved templates (Phase 2) |
| POST | `/api/bdl-import/templates` | Save a new template (Phase 2) |

---

## Next Steps

### Immediate (Next Session)
1. **Step 6: Review & Execute** — XML construction from catalog + validated staging data, file write to dmfs, DM API calls
2. **DM API credentials** — Verify/set up in `dbo.Credentials` / `dbo.CredentialServices`
3. **FA-SQLDBB write access** — Test whether the xFACts service account can write to dmfs shares
4. **End-to-end test** — Phone import on DM-TEST-APP with sample file
5. **`display_name` enrichment** — Populate friendly names across PHONE entity elements (and others as reviewed)
6. **UI refinements** — Fine-tune two-column layout proportions, evaluate compact mode behavior

### Phase 2
- Template save/load (table design + UI)
- Import history view on the BDL Import page
- Admin UI for AccessFieldConfig management
- Admin UI for `is_active` toggle on format tables
- `display_name` enrichment across additional entity elements

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
- `is_not_nullifiable` — From Excel spec. Means "cannot be included in nullify_fields during update operations." **NOT the same as required for import.** Not used in any required checks.
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
| BDLImport.ps1 | Route | BDL Import CC page route (two-column layout) |
| BDLImport-API.ps1 | API | BDL Import CC API endpoints |
| bdl-import.js | JavaScript | BDL Import CC client-side logic |
| bdl-import.css | CSS | BDL Import CC styles |

### ControlCenter.Shared Component
| Object | Type | Description |
|--------|------|-------------|
| xFACts-Helpers.psm1 | Module | Shared helper functions (incl. Invoke-XFActsNonQuery) |

### DeptOps.ApplicationsIntegration Component
| Object | Type | Description |
|--------|------|-------------|
| ApplicationsIntegration.ps1 | Route | Apps/Int CC page route |
| applications-integration.css | CSS | Apps/Int CC styles |

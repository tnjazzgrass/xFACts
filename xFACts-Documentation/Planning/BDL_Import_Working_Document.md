# BDL Import Module -- Working Document

**Status:** In development -- 5-step wizard operational for FILE_MAPPED and FIXED_VALUE entities, multi-entity selection with per-entity loop, CONSUMER_TAG end-to-end verified  
**Audience:** Dirk, Matt, Brandon, Claude  
**Last Updated:** April 9, 2026  
**Replaces:** `BDL_Import_Module_Design.md`, `BDL_Catalog_Reload_Instructions.md`, `xFACts_Questions_For_Matt.md`, `BDL_Action_Sequences_Planning.md`

> **Note:** The `BDL_Action_Sequences_Planning.md` document has been merged into this file and should be deleted from the repository.

---

## Overview

A Control Center page (`/bdl-import`) that allows authorized users to upload a vendor data file, select one or more BDL entity types, map columns to BDL fields (or enter fixed values for tag-type entities), validate the data against DM reference tables, preview generated XML, and trigger BDL imports into Debt Manager. Multi-entity selection is supported -- the system walks through mapping and validation for each entity independently using the same uploaded file.

Accessible via card links from the Applications & Integration page (IT team) and the Business Intelligence page (BI team). RBAC controls page access; `Tools.AccessConfig` controls entity-level access per department; `Tools.AccessFieldConfig` controls field-level access per department (strict whitelist).

---

## Current State

### What's Built and Deployed

**Database infrastructure (Tools schema):**
- `tools_enabled` column on `dbo.ServerRegistry` -- master switch for Tools server participation (7 app servers enabled)
- `Tools.ServerConfig` -- 3 rows (one per environment) with API URLs, dmfs paths, `db_instance`, and pipeline folder names for environment-specific targeting
- `Tools.AccessConfig` -- department-scoped entity access control (BI seeded with PHONE and CONSUMER_TAG)
- `Tools.AccessFieldConfig` -- field-level whitelist, child of AccessConfig. Strict whitelist: no child rows = zero field access. Admin tier bypasses entirely. BI seeded with PHONE and CONSUMER_TAG fields.
- `Tools.BDL_ImportLog` -- import execution audit trail with lifecycle status tracking, `column_mapping` JSON, `value_changes` column for replacement audit, `file_registry_id` from DM API, `parent_log_id` self-referential FK for linking AR log companion rows to their parent primary import, and `staging_table` column for test-to-prod correlation tracking
- `Tools.BDL_ImportTemplate` -- saved column mapping templates for vendor-specific file layouts. Columns: `template_id` (PK), `entity_type`, `template_name`, `description`, `column_mapping` (JSON), `is_active`, audit columns. Unique constraint on `entity_type + template_name`.
- `Staging` schema -- created for temporary import staging tables (not registered in xFACts platform, invisible to documentation pipeline)
- `AVG-STAGE-LSNR` added to `dbo.ServerRegistry` (AG_LISTENER, STAGE, DMSTAGEAG, is_active=0)
- `Tools.Operations` component -- registered and baselined

**Catalog_BDLFormatRegistry columns added:**
- `action_type VARCHAR(20)` -- controls mapping UI experience (FILE_MAPPED, FIXED_VALUE, HYBRID). CHECK constraint enforced. CONSUMER_TAG and ACCOUNT_TAG set to FIXED_VALUE.
- `entity_key VARCHAR(20)` -- identifies which DM identifier drives the import (CONSUMER, ACCOUNT, OTHER). CHECK constraint enforced. All 83 entities populated. Used for visual grouping on entity selection screen.
- `batch_abbreviation VARCHAR(14)` -- short code used in BDL XML batch_id_txt header element. Keeps batch ID within DM's 32-character column limit on file_rgstry_dtl.btch_idntfr_txt. Editable through admin catalog modal.

**NOTE:** `Tools.BDL_ActionRegistry` was designed, created, seeded, and then rolled back entirely during a prior session. Matt's feedback led to a simpler approach using entity types directly with multi-select cards instead of a separate action abstraction layer. Object_Registry and Object_Metadata rows for this table were also removed.

**DM API Integration (fully operational):**
- `dbo.CredentialServices` row for `DM_REST_API`
- `dbo.Credentials` rows for Username, Password, and AuthHeader (two-tier encrypted)
- Auth pattern mirrors Matt's legacy VBA toolkit exactly: `Authorization` header passed through as-is from stored `AuthHeader` value, `Content-Type: application/vnd.fico.dm.v1+json`
- API flow: POST `/fileregistry` (register file, extract `data.fileRegistryId` from response) -> POST `/fileregistry/{id}/bdlimport` (trigger import)
- File write uses BOM-less UTF-8 encoding (`New-Object System.Text.UTF8Encoding($false)`) -- DM's XML parser rejects BOM

**AR Log (Jira Ticket Link) -- fully operational:**
- `Build-ARLogXml` function in `xFACts-Helpers.psm1` -- constructs a `CONSUMER_ACCOUNT_AR_LOG` BDL XML from staging table data, creating one AR log entry per non-skipped row
- Uses CC/CC (clerical comment) action/result codes across all entity types -- internal codes that do not appear on client export notes
- Mirrors Matt's legacy VBA companion AR Event file pattern exactly
- Identifier element auto-detected: `cnsmr_idntfr_agncy_id` for consumer-level entities, `cnsmr_accnt_idntfr_agncy_id` for account-level
- AR log BDL is built and submitted as a separate file through the full register -> import cycle after the primary BDL succeeds
- AR log failure does NOT roll back the primary import
- AR log row in `BDL_ImportLog` uses `parent_log_id` to link back to the primary import row
- Default AR message format: `"{ticket}: {entity_type} update via BDL Import"` -- editable by the user
- Jira ticket field and AR message field are optional; if left blank, no AR log is generated

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
- `Build-BDLXml` added to `xFACts-Helpers.psm1` -- constructs BDL XML from staging table data and catalog metadata. Uses `batch_abbreviation` for batch ID construction. Includes `communication_reference_id_txt` header element.
- `Build-ARLogXml` added to `xFACts-Helpers.psm1` -- constructs CONSUMER_ACCOUNT_AR_LOG BDL XML for Jira ticket linking
- `Get-ServiceCredentials` in `xFACts-Helpers.psm1` -- two-tier decryption for DM API credentials

**Control Center pages:**
- `BDLImport.ps1` / `BDLImport-API.ps1` / `bdl-import.js` / `bdl-import.css` -- BDL Import wizard page (5-step layout)
- Two-column layout: 65% left (stepper bar + action panels) / 35% right (compact step guide + template section)
- Shared `engine-events.css` linked for slideout panel pattern, shared visual standards, and styled modal system (`xf-modal-*` classes)
- Shared `engine-events.js` linked for `showAlert()` and `showConfirm()` styled modal functions
- `ApplicationsIntegration.ps1` / `ApplicationsIntegration-API.ps1` / `applications-integration.js` / `applications-integration.css` -- Apps/Int departmental page with BDL Content Management admin modal
- BI page updated: BDL Import card now links to `/bdl-import`
- SheetJS `xlsx.full.min.js` v0.20.3 hosted locally for client-side Excel parsing

**BDL Content Management Admin Modal (Apps/Int page):**
- Two-tier slide-up/slideout panel, admin-only access
- Format list with active/inactive grouping, FIXED VALUE and HYBRID badges
- Element grid with inline edit (display_name, field_description as click-to-edit; is_visible, is_import_required as toggles)
- Format-level is_active toggle with confirmation
- `/api/apps-int/bdl-format/update` endpoint for editing format fields (action_type, batch_abbreviation editable)

**RBAC:**
- BDL Import page: Admin (wildcard), PowerUser/StandardUser = admin tier, ReadOnly = view, DeptStaff/DeptManager = operate
- Admin tier on BDL Import = unrestricted entity and field access (bypasses AccessConfig and AccessFieldConfig)
- Operate tier on BDL Import = entities filtered by AccessConfig, fields filtered by AccessFieldConfig (strict whitelist)
- Middleware fix applied: `Get-UserPageTier` honors department-scoped roles on non-departmental pages
- DBNull handling: API endpoints use `-isnot [System.DBNull]` check when extracting department scope

### What's Functional (5-Step Wizard)

1. **Select Environment** -- Cards for TEST, STAGE, PROD loaded from `Tools.ServerConfig`. Environment-specific accent colors. All environments unlocked. Selecting PROD shows a styled advisory modal.
2. **Upload File** -- Drag-and-drop or browse. CSV, TXT, XLSX, XLS supported via client-side parsing. Preview renders inside the drop zone. Row count warning above 250K.
3. **Select Entity Types** -- Multi-select grid with toggle cards grouped by `entity_key` (Consumer, Account, Other sections with headers). Field info modal (info icon) shows access-controlled field list with display names and descriptions on demand. Admin sees all active; department users see only AccessConfig-granted entities with AccessFieldConfig-filtered fields.
4. **Map & Validate** -- Per-entity loop with progress dots and transition modals. For FILE_MAPPED entities: identifier gating, two-column mapping panels, drag-and-drop. For FIXED_VALUE entities: identifier selector + direct value entry fields with debounced typeahead lookup against DM reference tables (300ms debounce, top 10 results with description from discovered _nm column). Each entity stages and validates independently. Step complete when all entities pass validation.
5. **Execute** -- Tabbed per-entity summary cards. Single Jira ticket field (applies to all). Submit All button processes entities sequentially. Per-tab success/failure indicators.

### End-to-End Test Results

**April 3, 2026 (TEST):**
- **Test 1 (Dirk):** 24-row PHONE file -> staged, validated, XML built, registered with DM (fileRegistryId 304146), import triggered, DM processed successfully. All 24 phone records confirmed in crs5_oltp.
- **Test 2 (Brandon):** ~5000-row PHONE file with ~1100 rows missing phone numbers -> staged, validated with skip, quality score filled, import submitted successfully.

**April 4, 2026 (PROD):**
- **Test 3 (Dirk):** PHONE BDL import into PRODUCTION -- 100% success. First production import via xFACts.

**April 4, 2026 (TEST - AR Log):**
- **Test 4 (Dirk):** 395-row file with Jira ticket link -> primary BDL submitted successfully, AR log companion BDL submitted successfully. Both files processed in DM with 395 records each.

**April 9, 2026 (TEST - Multi-Entity + FIXED_VALUE):**
- **Test 5 (Brandon):** Multi-entity test (PHONE + CONSUMER_TAG). PHONE submitted successfully (3,863 rows). CONSUMER_TAG initially failed with 400 error -- root cause was batch_id_txt exceeding DM's 32-character column limit on file_rgstry_dtl.btch_idntfr_txt. Fixed via batch_abbreviation column. Subsequent CONSUMER_TAG test successful.
- **Test 6 (Dirk):** CONSUMER_TAG standalone -- end-to-end success with typeahead tag lookup and fixed-value pipeline.

---

## Architecture Decisions (Resolved)

### 5-Step Wizard (consolidated from 6)
- Steps 2 and 3 swapped: Upload File precedes Entity Type selection (users should see their data before picking what to do with it)
- Old Steps 4 (Map) and 5 (Validate) merged into a single Map & Validate step with per-entity loop
- Step count reduced from 6 to 5: Environment, Upload File, Select Entities, Map & Validate, Execute

### Entity Selection Grouping
- Entity cards grouped by `entity_key` into visual sections: Consumer, Account, Other
- Section headers display conditionally -- only shown when entities exist in that group for the current user's access level
- Cards display entity name, folder classification, and field count
- Field info modal (info icon) fetches fields on demand via the existing entity-fields endpoint, respecting access control (admin sees all visible fields; department users see AccessFieldConfig-filtered fields)
- Field info modal shows display names in white, descriptions in smaller grey text

### Multi-Entity Selection
- Entity cards are toggle-selectable (click to select/deselect) instead of single-select
- `selectedEntities[]` array holds all selected entities; `entityStates[]` array holds per-entity state
- Each entity state independently tracks: fields, columnMapping, stagingContext, stagedMapping, validationResult, validated flag
- Step 3 completes when at least one entity is selected

### Per-Entity Map & Validate Loop
- Map then validate per entity (Brandon's recommendation) -- safer than mapping all first then validating all
- Progress dots with connecting lines show position in entity sequence
- 1.5-second transition modal between entities for visual breathing room
- Back button navigates through entities in reverse; entity 1 back goes to Step 3
- All entity states preserved on back navigation -- nothing lost
- Step 4 complete only when ALL entities pass validation

### Action Types on Catalog_BDLFormatRegistry
- `action_type VARCHAR(20)` with CHECK constraint: FILE_MAPPED (default), FIXED_VALUE, HYBRID
- Determines which mapping UI is rendered for each entity type
- Manageable through the admin catalog modal on the Apps/Int page
- FILE_MAPPED: full column mapping panels with drag-and-drop (existing behavior)
- FIXED_VALUE: simplified panel with identifier selector + value entry fields
- HYBRID: reserved for future -- combination of mapped and fixed fields

### Fixed-Value Mapping UI
- Different UI rendered for entities with `action_type = 'FIXED_VALUE'`
- Identifier column selector (same as file-mapped -- which column has the agency ID?)
- Direct value entry fields for each non-identifier visible field
- Lookup fields use debounced typeahead search (300ms) against DM reference tables via `/api/bdl-import/lookup-search`
- Typeahead discovers the search column from `element_name`, active flag from `_actv_flg` column, and description from `_nm` column dynamically via INFORMATION_SCHEMA
- Suggestions show value and description side by side; results cached per element+search term
- Values stored in `columnMapping` with `__fixed__` prefix keys
- Validate button enabled when identifier is selected and all required fields have values

### Fixed-Value Staging Pipeline
- Fixed values stored in `columnMapping` with `__fixed__` prefix keys (e.g., `__fixed__tag_shrt_nm`)
- Stage request separates `mapping` (file-to-column) from `fixed_values` (user-entered)
- Server adds columns for fixed values (ALTER TABLE if needed) and UPDATEs all rows with those values
- Validation runs normally against the staged data -- same validation infrastructure as FILE_MAPPED
- Optional fields left blank are simply not included in the staging table or XML -- DM applies its own defaults (e.g., tag assignment date defaults to current timestamp)

### Tabbed Execute
- One tab per entity type with individual summary card
- Single Jira ticket field above tabs (applies to all imports)
- `executeSequential()` processes each entity one at a time, auto-switching tabs
- Tab labels get check or X indicators as each completes
- Each entity submits independently -- one failure does not halt others

### BDL_ActionRegistry -- Built and Rolled Back
- Table was designed and built to map user-friendly action names to entity types
- After discussion with Matt, the approach was simplified -- users select entity types directly
- Table and all related Object_Registry/Object_Metadata rows were cleaned up
- AccessConfig `item_key` stayed as entity_type (no migration to action_key)

### Template System
- `Tools.BDL_ImportTemplate` stores reusable column mappings as JSON per entity type
- Templates visible to all users; creator or admin can update/delete (soft delete via `is_active = 0`)
- Template preview via shared slideout panel showing field-by-field matching against current file
- Case-insensitive header matching when applying
- Templates load for the current entity in the multi-entity loop

### Back Navigation and Staging Reuse
- Column mapping preserved on back navigation (not reset to empty)
- Identifier dropdown selection restored on re-render
- If mapping unchanged from what was staged, existing staging table is reused (no re-stage). If mapping changed, old staging table is dropped via `drop_existing` parameter.

### Cascading Validation
- Validation issues presented as accordion cards -- one expandable at a time
- Required empty and lookup invalid are actionable (fill/replace/skip controls)
- Max length and data type are informational only
- Auto re-validate fires after each fill/skip action
- Cascading effect: skipping rows for one field removes those rows from subsequent checks
- User interaction disabled during re-validate cycle

### AR Log Companion Pattern
- When a Jira ticket is provided, generates two separate BDL files per entity: primary data + companion CONSUMER_ACCOUNT_AR_LOG
- CC/CC action/result codes -- internal clerical comments that do not appear on client export notes
- `parent_log_id` on `BDL_ImportLog` links AR log row to primary import row
- AR log failure does not roll back primary import

### Identifier Field Gating
- Mapping panels disabled and dimmed until identifier column is selected
- Red border when unselected, green border when confirmed
- Applies to both FILE_MAPPED and FIXED_VALUE entity types

### Promote to Production
- After successful non-PROD import, Promote to Production card appears with GlobalConfig-driven countdown timer
- Infrastructure exists: state variables, CSS styles, GlobalConfig `bdl_promote_cooldown_seconds`, `prod_config_id` in API response
- UI rendering was lost during the 5-step tabbed execute restructure -- needs to be re-wired (follow-up item)

### Styled Modal System
- All native dialogs replaced with `showAlert()`/`showConfirm()` from `engine-events.js`
- BDL Import is the reference implementation
- Development Guidelines Section 5.10 updated with shared modal function documentation and BOLO for legacy native dialogs on other pages

### Guide Panel
- Compact tip panel in upper right column
- Content updates automatically based on current step (5 steps)

### Server Configuration
- `tools_enabled` on ServerRegistry = master switch for Tools server participation
- `Tools.ServerConfig` = per-environment operational config
- `db_instance` stores the database server/listener per environment

### DM API Authentication
- Credentials stored in `dbo.Credentials` under `ServiceName = 'DM_REST_API'`
- Two-tier encryption: master passphrase -> service passphrase -> credential values
- `AuthHeader` stores complete `Basic <base64>` string

### XML Construction
- XML built entirely from catalog data via `Build-BDLXml` in `xFACts-Helpers.psm1`
- File extension is `.txt`
- BOM-less UTF-8 encoding
- `communication_reference_id_txt` header element always included, hardcoded to "Organization"
- Batch ID constructed as `XF_{batch_abbreviation}_{yyyyMMddHHmmss}` -- must not exceed 32 characters (DM `file_rgstry_dtl.btch_idntfr_txt` column limit)
- Wrapper element (`consumer_operational_transaction_data` or `account_operational_transaction_data`) resolved from catalog; most entities appear under both wrappers in the XSD -- current code takes the first match. XSD files available on the DM application server for reference if wrapper issues arise with new entity types.

### Access Control (Three Layers)
1. **RBAC page access** -- `RBAC_PermissionMapping` controls who can see the page
2. **Entity access** -- `Tools.AccessConfig` controls which BDL entity types a department can use
3. **Field access** -- `Tools.AccessFieldConfig` controls which fields a department can see/use

### Staging Architecture
- Tables created in `Staging` schema
- Table naming: `Staging.BDL_{entity}_{username}_{timestamp}`
- All columns stored as VARCHAR
- Bulk INSERT in batches of 500 rows
- Fixed-value columns added via ALTER TABLE and populated via UPDATE after bulk insert
- Re-staging drops old table atomically via `drop_existing` parameter

### Import Lifecycle
- Status progression: BUILDING -> REGISTERED -> SUBMITTED / FAILED
- Column mapping captured as JSON in `BDL_ImportLog.column_mapping`
- Completion tracking deferred to BatchOps BDL monitoring collector

### RBAC Middleware: Department-Scoped Roles on Shared Pages
- Fix: explicit permission rows always honored regardless of department scope

### Identifier Handling
- Consumer-level: `cnsmr_idntfr_agncy_id`
- Account-level: `cnsmr_accnt_idntfr_agncy_id`
- Only agncy_id works reliably per Matt
- Identifier must be selected before mapping is enabled

---

## Matt's Answers (From Sessions)

### Before Build (All Answered)
1. **DM API Credentials:** Confirmed. Auth is Basic auth with pre-built Authorization header.
2. **dmfs File Paths:** Confirmed correct. Stored in Tools.ServerConfig.
3. **First Entity Types:** Phone, Consumer Tags, Account Tags recommended.
4. **Legacy Toolkit:** Unmapped functions are dead code.

### During Build (All Answered)
5. **Companion File Pattern:** Can be combined into single BDL file.
6. **Concurrent Imports:** Fine, but don't overwhelm DM.
7. **File Size / Row Limits:** Practical limit ~250K rows.
8. **Error Recovery:** New file with new name required.
9. **Catalog Data Quality:** Duplicate Case Tag/Case History are documentation issue.
10. **`is_not_nullifiable` is NOT "required for import."** Only `is_import_required` used for required field checks.
11. **`cnsmr_phn_qlty_score_nmbr` is required by the XSD.** Without it, BDL runs but silently does nothing.
12. **`is_not_nullifiable` repurposed for validation UI skip logic.** Controls whether Skip button appears.

### Multi-Entity Session (April 9)
13. **Multi-tag same file:** Possible -- repeating pattern with sequential seq_no, NOT contained in same entry.
14. **Consumer + Account mix:** Theoretically possible but no current processes do it.
15. **Tag case sensitivity:** Not case sensitive.
16. **Same source column mapped to multiple BDLs:** Pending -- checking with Brandon.
17. **Entity type selection approach:** Users are knowledgeable enough to select entity types directly; friendly action name abstraction layer (BDL_ActionRegistry) was unnecessary overhead. Field info modal provides enough context.

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
After registration, DM processes the file asynchronously: NEW (1) -> UPDATING (2) -> READY (3) -> PROCESSING (4) -> PROCESSED (5). If content is invalid, goes to FAILED (6).

### XML Header Structure
```xml
<?xml version="1.0" encoding="UTF-8"?>
<dm_data xmlns="http://www.fico.com/xml/debtmanager/data/v1_0">
  <header>
    <sender_id_txt>Organization</sender_id_txt>
    <target_id_txt>FAC Debt Manager</target_id_txt>
    <batch_id_txt>XF_PHN_20260409140634</batch_id_txt>
    <communication_reference_id_txt>Organization</communication_reference_id_txt>
    <operational_transaction_type>CONSUMER</operational_transaction_type>
    <total_count>24</total_count>
    <creation_data>2026-04-09T14:06:00</creation_data>
    <custom_properties>
      <custom_property/>
    </custom_properties>
  </header>
  <operational_transaction_data>
    <consumer_operational_transaction_data>
      ...entity elements...
    </consumer_operational_transaction_data>
  </operational_transaction_data>
</dm_data>
```

### DM Internal Reference: Operational Transaction Types
DM maps the `operational_transaction_type` header value to an internal ID via `Ref_entty_assctn_cd` then `bdl_oprtnl_trnsctn_typ`. The `batch_id_txt` value is stored in `file_rgstry_dtl.btch_idntfr_txt` (VARCHAR(32)). XSD files for all BDL entity types are available on the DM application server under the BDL schema directory for reference when onboarding new entity types.

---

## Implemented CC API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/bdl-import/environments` | Available environments from ServerConfig |
| GET | `/api/bdl-import/entities` | Available entity types with `action_type`, `entity_key` (RBAC + is_active filtered) |
| GET | `/api/bdl-import/entity-fields?entity_type=X` | BDL fields for an entity (admin: all visible; dept: AccessFieldConfig whitelist) |
| GET | `/api/bdl-import/lookup-search` | Typeahead search against DM lookup tables. Params: lookup_table, element_name, search, config_id. Discovers active flag and description columns dynamically. |
| POST | `/api/bdl-import/stage` | Create staging table, insert rows, apply fixed values. Optional drop_existing, fixed_values. |
| POST | `/api/bdl-import/validate` | Read staging table + fetch lookups from DM (repeatable) |
| POST | `/api/bdl-import/replace-values` | Mass-replace values in staging table column |
| POST | `/api/bdl-import/skip-rows` | Mark rows as skipped in staging table |
| GET | `/api/bdl-import/staging-cleanup` | Check for expired staging tables (>48 hours) |
| POST | `/api/bdl-import/staging-cleanup` | Drop expired staging tables |
| GET | `/api/bdl-import/history` | Recent import history from BDL_ImportLog |
| POST | `/api/bdl-import/build-preview` | Build XML and return for preview |
| POST | `/api/bdl-import/execute` | Full pipeline: build XML -> write -> register -> trigger. Optional AR log. |
| GET | `/api/bdl-import/templates?entity_type=X` | List saved templates for an entity type |
| POST | `/api/bdl-import/templates` | Save a new template |
| PUT | `/api/bdl-import/templates/:id` | Update a template (creator or admin only) |
| DELETE | `/api/bdl-import/templates/:id` | Deactivate a template (creator or admin only) |

---

## Next Steps

### Immediate (Resume Point)

1. **Multi-entity row count alignment** -- When multiple entities are selected and rows are skipped during validation of one entity, the other entities' staging tables still contain the full row set. Need a cross-entity key comparison modal on Step 5 that identifies mismatched row counts and offers alignment (mark extra rows as skipped in companion entities) before enabling Submit All.

2. **XML preview per tab** -- The Execute step (Step 5) previously had XML preview capability that was lost during the 5-step consolidation. Restore per-entity XML preview within each tab on the execute screen.

3. **Promote to Production** -- Infrastructure exists (state variables, CSS, GlobalConfig cooldown setting, prod_config_id in API response) but the UI rendering was lost during the tabbed execute restructure. Re-wire the promote card rendering and click handler into the new tabbed execute flow.

4. **`import_guidance` column on Catalog_BDLElementRegistry** -- Operational tips for fields during import (e.g., "Required numeric value -- enter 0 if not in source data" for phone quality score, "Optional -- defaults to current timestamp if blank" for tag assignment date). Separate from `field_description` which documents what the field is.

5. **Version bumps** -- Deferred from April 6, April 8, and April 9 sessions. Multiple components touched: Tools.Operations (action_type, entity_key, batch_abbreviation columns), Tools.Catalog (element registry is_import_required updates), ControlCenter.BDLImport (5-step consolidation, multi-select, per-entity loop, fixed-value UI, typeahead, entity grouping, field info modal, tabbed execute), DeptOps.ApplicationsIntegration (API file, JS file, CSS badges).

### Follow-Up Items

- **Multi-tag "Add Another" pattern** -- Entering multiple tag values for the same entity, generating one row per consumer per tag with sequential `seq_no`. Tags use a repeating pattern where each tag gets its own entry (not contained within the same entry).
- **HYBRID action_type UI** -- Reserved but not yet implemented. Combination of file-mapped and manually entered fields.
- **Same source column mapped to multiple BDLs** -- Pending Brandon's input on whether this is a real scenario.
- **Step guide text refinement** -- Right-column guidance for each step.
- **Template UX refinement** -- User feedback on template workflow.
- **Typeahead lookup column discovery** -- Current discovery logic finds `_actv_flg` and `_nm` columns dynamically. If future lookup tables use different naming patterns for active flags or descriptions, the discovery may need expansion.
- **Wrapper element selection** -- Most entity types appear under both `consumer_operational_transaction_data` and `account_operational_transaction_data` in the XSD. Current code takes the first match from the catalog. This works for PHONE and CONSUMER_TAG but may need a `wrapper_format_id` column on `Catalog_BDLFormatRegistry` if future entities require a specific wrapper that differs from the default first-match behavior.
- **`custom_properties` XML block** -- Currently included as an empty `<custom_property/>` element. May not be needed; successful third-party tag imports omit it entirely. Consider removing.

### Phase 2

- Import history view on the BDL Import page
- Admin UI for AccessFieldConfig management
- `display_name` enrichment across additional entity elements
- Staging table resume/review capability
- **BatchOps BDL monitoring collector** -- Pulls BDL processing results from DM. Writes completion status back to `Tools.BDL_ImportLog` via `file_registry_id`. Cross-module: collector lives in BatchOps, write-back targets Tools schema.

### Future Enhancements

- Payment Import pipeline (separate XML schema and API flow)
- CDL Import pipeline
- Consumer/Account CRUD Operations
- DM Monitoring Dashboard widgets
- New Business Import pipeline

---

## Catalog Table Reference

### Tools.Catalog_BDLFormatRegistry
One row per BDL entity type. Parent table. Key columns: `format_id` (PK), `entity_type`, `type_name`, `folder`, `element_count`, `has_nullify_fields`, `is_active`, `action_type`, `entity_key`, `batch_abbreviation`.

### Tools.Catalog_BDLElementRegistry
One row per element within each entity type. Child table via `format_id` FK. Key columns: `element_name`, `display_name`, `data_type`, `max_length`, `table_column`, `lookup_table`, `is_not_nullifiable`, `is_primary_id`, `is_visible`, `is_import_required`, `field_description`.

### Three "Required" Columns (Disambiguation)
- `is_required` -- XSD `minOccurs`. Almost always 0. Not useful for import decisions.
- `is_not_nullifiable` -- From Excel spec. Means "cannot be included in nullify_fields." Also controls Skip button visibility on required empty fields.
- `is_import_required` -- Practical requirement from operational experience. Set by Matt. **This is the only flag used for required field validation and hard blocks.**

### Lookup Table Discovery Pattern
For fields with `lookup_table` populated, the typeahead and validation endpoints discover columns dynamically:
- **Search column:** The `element_name` itself matches a column in the lookup table (e.g., `tag_shrt_nm` in `dbo.tag`)
- **Active flag:** First column matching `*_actv_flg` pattern (e.g., `tag_actv_flg`)
- **Description:** First column matching `*_nm` pattern that is not the search column (e.g., `tag_nm`)

---

## Database Object Inventory

### Tools.Operations Component
| Object | Type | Description |
|--------|------|-------------|
| ServerConfig | Table | Per-environment DM server configuration (incl. db_instance) |
| AccessConfig | Table | Department-scoped tool/entity access control |
| AccessFieldConfig | Table | Field-level whitelist, child of AccessConfig |
| BDL_ImportLog | Table | Import execution audit trail (incl. parent_log_id for AR log linking) |
| BDL_ImportTemplate | Table | Saved column mapping templates |

### ControlCenter.BDLImport Component
| Object | Type | Description |
|--------|------|-------------|
| BDLImport.ps1 | Route | BDL Import CC page route (5-step layout) |
| BDLImport-API.ps1 | API | BDL Import CC API endpoints (incl. template CRUD, AR log, fixed_values staging, lookup search) |
| bdl-import.js | JavaScript | BDL Import CC client-side logic (multi-entity, per-entity state, fixed-value UI, typeahead, entity grouping) |
| bdl-import.css | CSS | BDL Import CC styles |

### ControlCenter.Shared Component
| Object | Type | Description |
|--------|------|-------------|
| xFACts-Helpers.psm1 | Module | Shared helpers (Invoke-XFActsNonQuery, Build-BDLXml, Build-ARLogXml, Get-ServiceCredentials) |

### DeptOps.ApplicationsIntegration Component
| Object | Type | Description |
|--------|------|-------------|
| ApplicationsIntegration.ps1 | Route | Apps/Int CC page route (admin modal HTML) |
| ApplicationsIntegration-API.ps1 | API | Apps/Int CC API endpoints (BDL catalog management, format update) |
| applications-integration.js | JavaScript | Apps/Int CC client-side logic (BdlCatalog module) |
| applications-integration.css | CSS | Apps/Int CC styles (catalog modal, badges) |

### Credential Infrastructure
| Object | Location | Description |
|--------|----------|-------------|
| DM_REST_API | dbo.CredentialServices | Service registration for DM REST API |
| Username | dbo.Credentials | DM API username (apiuser), encrypted |
| Password | dbo.Credentials | DM API password, encrypted |
| AuthHeader | dbo.Credentials | Complete Basic auth header string, encrypted |

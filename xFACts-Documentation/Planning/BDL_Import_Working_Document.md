# BDL Import Module -- Working Document

**Status:** In development -- 5-step wizard operational with XML preview, unified execution results, row count alignment, Promote to Production, environment badge, consolidated AR log, import_as_user_name, BDL Permissions Admin Modal, import_guidance, nullify fields (blanket + record-level), Excel date formatting. Multi-entity + FIXED_VALUE end-to-end verified. Multi-assignment cards with blanket/conditional/from-file modes. Per-field mode selector for conditional-eligible fields on FILE_MAPPED entities (3-way: File/Blanket/Conditional). 4-step dynamic lookup column discovery for validation and typeahead. ServerConfig renamed to EnvironmentConfig. ServerRegistry API targeting deployed. ActionAuditLog redesigned. BDL Import user guide deployed.  
**Audience:** Dirk, Matt, Brandon, Claude  
**Last Updated:** April 15, 2026  
**Replaces:** `BDL_Import_Module_Design.md`, `BDL_Catalog_Reload_Instructions.md`, `xFACts_Questions_For_Matt.md`, `BDL_Action_Sequences_Planning.md`

---

## Overview

A Control Center page (`/bdl-import`) that allows authorized users to upload a vendor data file, select one or more BDL entity types, map columns to BDL fields (or enter fixed values for tag-type entities), validate the data against DM reference tables, preview generated XML, and trigger BDL imports into Debt Manager. Multi-entity selection is supported -- the system walks through mapping and validation for each entity independently using the same uploaded file.

Accessible via card links from the Applications & Integration page (IT team) and the Business Intelligence page (BI team). RBAC controls page access; `Tools.AccessConfig` controls entity-level access per department; `Tools.AccessFieldConfig` controls field-level access per department (strict whitelist).

---

## Current State

### What's Built and Deployed

**Database infrastructure (Tools schema):**
- `tools_enabled` column on `dbo.ServerRegistry` -- master switch for Tools server participation (7 app servers enabled)
- `api_base_url VARCHAR(200)` and `is_api_primary BIT` columns on `dbo.ServerRegistry` -- API targeting for all 7 tools-enabled app servers. ServerRegistry is now the single source of truth for API URLs. Single-server operations query `WHERE is_api_primary = 1`; all-server operations iterate `WHERE api_base_url IS NOT NULL AND tools_enabled = 1`.
- `Tools.EnvironmentConfig` (formerly ServerConfig) -- 3 rows (one per environment) with dmfs paths, `db_instance`, and pipeline folder names. Server-specific columns removed; API URLs sourced from `dbo.ServerRegistry`.
- `Tools.AccessConfig` -- department-scoped entity access control (BI seeded with PHONE and CONSUMER_TAG)
- `Tools.AccessFieldConfig` -- field-level whitelist, child of AccessConfig. Strict whitelist: no child rows = zero field access. Admin tier bypasses entirely. BI seeded with PHONE and CONSUMER_TAG fields.
- `Tools.BDL_ImportLog` -- import execution audit trail with lifecycle status tracking, `column_mapping` JSON, `value_changes` column for replacement audit, `file_registry_id` from DM API, `parent_log_ids` (VARCHAR(200)) comma-separated list of primary import log_id values for consolidated AR log linking, and `staging_table` column for test-to-prod correlation tracking
- `Tools.BDL_ImportTemplate` -- saved column mapping templates for vendor-specific file layouts. Columns: `template_id` (PK), `entity_type`, `template_name`, `description`, `column_mapping` (JSON), `is_active`, audit columns. Unique constraint on `entity_type + template_name`.
- `Staging` schema -- created for temporary import staging tables (not registered in xFACts platform, invisible to documentation pipeline)
- `AVG-STAGE-LSNR` added to `dbo.ServerRegistry` (AG_LISTENER, STAGE, DMSTAGEAG, is_active=0)
- `Tools.Operations` component -- registered and baselined

**Platform infrastructure (April 13):**
- `dbo.ActionAuditLog` redesigned -- universal user action audit trail replacing the original field-level config change tracking structure. New columns: `page_route`, `action_type`, `action_summary`, `environment`, `result`, `error_detail`, `executed_by`, `executed_dttm`. 91 legacy rows migrated. All existing writers in `Admin-API.ps1` (5 INSERTs + 1 SELECT) and `JBossMonitoring-API.ps1` (1 INSERT) updated. Serves dual purpose: audit trail and cooldown enforcement for throttled operations.

**Catalog_BDLFormatRegistry columns added:**
- `action_type VARCHAR(20)` -- controls mapping UI experience (FILE_MAPPED, FIXED_VALUE, HYBRID). CHECK constraint enforced. CONSUMER_TAG and ACCOUNT_TAG set to FIXED_VALUE.
- `entity_key VARCHAR(20)` -- identifies which DM identifier drives the import (CONSUMER, ACCOUNT, OTHER). CHECK constraint enforced. All 83 entities populated. Used for visual grouping on entity selection screen.
- `batch_abbreviation VARCHAR(14)` -- short code used in BDL XML batch_id_txt header element. Keeps batch ID within DM's 32-character column limit on file_rgstry_dtl.btch_idntfr_txt. Editable through admin catalog modal.

**Catalog_BDLElementRegistry columns added:**
- `import_guidance VARCHAR(500)` -- operational tips for fields during import (e.g., "Required numeric value -- enter 0 if not in source data" for phone quality score, "Optional -- defaults to current timestamp if blank" for tag assignment date). Separate from `field_description` which documents what the field is. Editable through admin catalog modal (Global Configuration mode). Displayed in field info modal, fixed-value UI, mapping chips, and validation card bodies.
- `is_conditional_eligible BIT DEFAULT 0` -- identifies fields eligible for per-field mode selection during BDL Import. When set to 1, FILE_MAPPED entities show a 3-way toggle (File/Blanket/Cond) on the target chip; FIXED_VALUE entities show a 3-way toggle (File/Blanket/Cond) on the assignment card. Currently set on `tag_shrt_nm` for CONSUMER_TAG and ACCOUNT_TAG, and `wrkgrp_shrt_nm` for CONSUMER.

**Staging table enhancements (April 15):**
- `_trigger_value VARCHAR(200)` system column added to staging tables created via the assignments path. Stores the trigger column value that produced each row (NULL for blanket and from-file assignments). Available for debugging and potential secondary record retention.
- `_assignment_index INT` system column tracks which assignment card generated each row.
- `Build-BDLXml` exclusion filter updated to exclude `_trigger_value` and `_assignment_index` from XML output (same pattern as `_row_number`, `_skip`, `_nullify_fields`).

**NOTE:** `Tools.BDL_ActionRegistry` was designed, created, seeded, and then rolled back entirely during a prior session. Matt's feedback led to a simpler approach using entity types directly with multi-select cards instead of a separate action abstraction layer. Object_Registry and Object_Metadata rows for this table were also removed.

**DM API Integration (fully operational):**
- `dbo.CredentialServices` row for `DM_REST_API`
- `dbo.Credentials` rows for Username, Password, and AuthHeader (two-tier encrypted)
- Auth pattern mirrors Matt's legacy VBA toolkit exactly: `Authorization` header passed through as-is from stored `AuthHeader` value, `Content-Type: application/vnd.fico.dm.v1+json`
- API flow: POST `/fileregistry` (register file, extract `data.fileRegistryId` from response) -> POST `/fileregistry/{id}/bdlimport` (trigger import)
- File write uses BOM-less UTF-8 encoding (`New-Object System.Text.UTF8Encoding($false)`) -- DM's XML parser rejects BOM

**AR Log (Jira Ticket Link) -- consolidated per batch:**
- Single consolidated `CONSUMER_ACCOUNT_AR_LOG` BDL file per batch execution, replacing the earlier per-entity pattern
- After all primary entity imports complete, if a Jira ticket was provided and at least one entity succeeded, one AR log file is built from the first successful entity's staging table and submitted automatically
- AR message references all entity types: e.g., `"SD-1234: PHONE, CONSUMER_TAG update via BDL Import"`
- Dedicated endpoint `POST /api/bdl-import/execute-ar-log` handles the consolidated AR log independently from per-entity execute calls
- `parent_log_ids` stores comma-separated list of all primary import log_id values the AR log covers
- Uses CC/CC (clerical comment) action/result codes -- internal codes that do not appear on client export notes
- Identifier element auto-detected: `cnsmr_idntfr_agncy_id` for consumer-level entities, `cnsmr_accnt_idntfr_agncy_id` for account-level
- AR log failure does NOT roll back primary imports; result rendered in unified results pane
- `Build-ARLogXml` in `xFACts-Helpers.psm1` constructs the XML

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
- `Build-BDLXml` added to `xFACts-Helpers.psm1` -- constructs BDL XML from staging table data and catalog metadata. Uses `batch_abbreviation` for batch ID construction. Includes `communication_reference_id_txt` and `import_as_user_name` header elements. Supports blanket nullify (from `_nullify_fields` column) and record-level nullify (empty mapped columns auto-nullified for entities with `has_nullify_fields = 1`, excluding `is_not_nullifiable` fields).
- `Build-ARLogXml` added to `xFACts-Helpers.psm1` -- constructs CONSUMER_ACCOUNT_AR_LOG BDL XML for Jira ticket linking. Includes `import_as_user_name` header element.
- `Get-ServiceCredentials` in `xFACts-Helpers.psm1` -- two-tier decryption for DM API credentials
- `import_as_user_name` added to XML headers in both `Build-BDLXml` and `Build-ARLogXml` -- passes authenticated CC user's AD username to DM so imports are attributed to the actual user instead of apiuser. DM falls back to apiuser silently if the username is not recognized.

**Control Center pages:**
- `BDLImport.ps1` / `BDLImport-API.ps1` / `bdl-import.js` / `bdl-import.css` -- BDL Import wizard page (5-step layout)
- Two-column layout: 65% left (stepper bar + action panels) / 35% right (compact step guide + template section)
- Shared `engine-events.css` linked for slideout panel pattern, shared visual standards, and styled modal system (`xf-modal-*` classes)
- Shared `engine-events.js` linked for `showAlert()` and `showConfirm()` styled modal functions
- `ApplicationsIntegration.ps1` / `ApplicationsIntegration-API.ps1` / `applications-integration.js` / `applications-integration.css` -- Apps/Int departmental page with BDL Content Management admin modal
- BI page updated: BDL Import card now links to `/bdl-import`
- SheetJS `xlsx.full.min.js` v0.20.3 hosted locally for client-side Excel parsing

**Documentation (April 13):**
- `bdl-import-guide.html` -- standalone step-by-step user guide with visual mockups covering all 5 wizard steps, deployed to `pages/guides/`
- `tools.html` -- updated with User Guides card section linking to guide pages
- Documentation pipeline updated: auto-discovery of guide pages from `pages/guides/*.html` (title from `<h1>`, parent from breadcrumb), `Convert-GuideToStorageFormat`, `Convert-GuideToMarkdown`, Phase 1.7 Confluence publishing, markdown export integration
- `Consolidate-UploadFiles.ps1` and `Publish-GitHubRepository.ps1` updated for guides folder

**Multi-Assignment Cards (April 15):**
- FIXED_VALUE entity mapping panel uses an assignment card model
- Each assignment is an independent card with File, Blanket, or Conditional mode (3-way toggle shown when entity has conditional-eligible fields)
- File mode: conditional-eligible field value read from a selected file column; shared (non-conditional) fields entered manually below the column selector
- Blanket mode: same value entry UI for all fields, scoped to the assignment card
- Conditional mode: trigger column selector scans full file for unique values, renders grid with per-value typeahead against DM reference tables, shared fields section for non-varying fields
- "Add Another" button stacks multiple assignments (any mix of file/blanket/conditional supported)
- Remove button on all cards except the first (minimum one assignment required)
- File/Blanket/Conditional toggle only appears when entity has at least one `is_conditional_eligible` field; entities without conditional-eligible fields show blanket-only cards
- Staging expansion: client sends `assignments` array to stage endpoint; server generates expanded rows (one per identifier per applicable assignment) with consumer-grouped ordering matching established BDL XML pattern
- `readFileColumnValues()` client-side helper async-reads full file for unique value extraction when trigger column is selected
- 15+ unique values trigger "show all" toggle for trigger grid overflow
- Assignment state comparison for re-staging detection: serialized assignments snapshot compared alongside columnMapping to detect changes requiring re-staging
- Backward compatible: entities without assignments still use original fixed_values staging path

**Per-Field Mode Selector for FILE_MAPPED entities (April 15):**
- Conditional-eligible fields on FILE_MAPPED entities display a compact 3-way toggle on the target chip: `[File | Blanket | Cond]`
- "File" (default): standard drag-drop mapping from a source column -- field stays in the target panel with normal click/drag behavior
- "Blanket": one fixed value applied to all rows -- field moves from target panel to a Field Assignments section below the mapping panels, renders as an assignment card with value input (typeahead for lookup fields)
- "Conditional": value varies per row based on a trigger column -- same assignment card pattern with trigger column selector, unique value grid, per-value typeahead
- Toggling back to "File" returns the field to the target panel
- Field Assignments section only appears when at least one field is in Blanket or Conditional mode
- State stored in `fieldAssignments` object on entity state, keyed by `element_name`
- Staging: client sends `field_assignments` in the stage request; server creates staging table from file data normally (Path B), then adds assignment field columns via ALTER TABLE and populates via UPDATE (blanket) or per-trigger-value UPDATEs (conditional)
- Validated/complete and Execute summary views show field assignment fields with `(fixed)` or `(cond)` mode tags alongside file-mapped fields
- First use case: CONSUMER entity with `wrkgrp_shrt_nm` for BI team workgroup reassignment

**4-Step Dynamic Lookup Column Discovery (April 15):**
- Validation and typeahead lookup endpoints use a universal 4-step column resolution instead of hardcoded `_val_txt` pattern
- Applies to both `POST /api/bdl-import/validate` (lookup value loading) and `GET /api/bdl-import/lookup-search` (typeahead search)
- Resolution order (short-circuits at first match):
  1. Direct match: `element_name` exists as a column in the lookup table (~75% of lookups)
  2. `*_val_txt` fallback: first column matching the pattern (ref tables with prefixed elements)
  3. `*_shrt_nm` fallback: first column matching the pattern (entity tables with prefixed elements)
  4. `*_nm` fallback (excluding `_shrt_nm`): first column matching the pattern (entity tables like `fee_typ`, `pymnt_memo`)
- Active flag discovery unchanged (`*_actv_flg` pattern)
- Description column discovery updated: tries `*_nm` (excluding resolved column) first, then `*_dscrptn_txt` -- entity tables show `wrkgrp_nm`/`tag_nm`, ref tables show `*_dscrptn_txt`
- Table structure (column list + active flag) cached per-table for efficiency; value column resolved per-element
- Validated against all 52 distinct lookup tables across all BDL entity types -- zero exceptions

**BDL Content Management Admin Modal (Apps/Int page):**
- Two-tier slide-up/slideout panel, admin-only access
- Mode selector: "Global Configuration" (default) and "Department Access"
- **Global Configuration mode:**
  - Format list with active/inactive grouping, FIXED VALUE and HYBRID badges
  - Element grid with inline edit (display_name, field_description, import_guidance as click-to-edit; is_visible, is_import_required as toggles)
  - Format-level is_active toggle with confirmation
  - `/api/apps-int/bdl-format/update` endpoint for editing format fields (action_type, batch_abbreviation editable)
- **Department Access mode:**
  - Department dropdown from `RBAC_DepartmentRegistry` (excluding Apps/Int -- admin tier bypass handles their access)
  - Entity access toggles with "X of Y fields granted" stats per entity
  - Field-level granted toggles per department (display_name and field_description read-only -- edits happen in Global mode only)
  - UPSERT pattern (MERGE) on both entity and field access toggles
  - Ungranted entities block tier 2 field management (FK constraint enforced)
  - 5 new API endpoints: departments, bdl-access, bdl-field-access, bdl-access/toggle, bdl-field-access/toggle

**RBAC:**
- BDL Import page: Admin (wildcard), PowerUser/StandardUser = admin tier, ReadOnly = view, DeptStaff/DeptManager = operate
- Admin tier on BDL Import = unrestricted entity and field access (bypasses AccessConfig and AccessFieldConfig)
- Operate tier on BDL Import = entities filtered by AccessConfig, fields filtered by AccessFieldConfig (strict whitelist)
- Middleware fix applied: `Get-UserPageTier` honors department-scoped roles on non-departmental pages
- DBNull handling: API endpoints use `-isnot [System.DBNull]` check when extracting department scope

### What's Functional (5-Step Wizard)

1. **Select Environment** -- Cards for TEST, STAGE, PROD loaded from `Tools.EnvironmentConfig`. Environment-specific accent colors. All environments unlocked. Selecting PROD shows a styled advisory modal.
2. **Upload File** -- Drag-and-drop or browse. CSV, TXT, XLSX, XLS supported via client-side parsing. Preview renders inside the drop zone. Row count warning above 250K.
3. **Select Entity Types** -- Multi-select grid with toggle cards grouped by `entity_key` (Consumer, Account, Other sections with headers). Field info modal (info icon) shows access-controlled field list with display names, descriptions, and import guidance on demand. Admin sees all active; department users see only AccessConfig-granted entities with AccessFieldConfig-filtered fields.
4. **Map & Validate** -- Per-entity loop with progress dots and transition modals. For FILE_MAPPED entities: identifier gating, two-column mapping panels, drag-and-drop, nullify badge on eligible target fields, per-field mode toggle on conditional-eligible fields. For FIXED_VALUE entities: identifier selector + multi-assignment card model with File/Blanket/Conditional mode per card. Each entity stages and validates independently. Validation cards show `import_guidance` tips when populated. Validated screen shows Mapped Fields card and Nullify card (when applicable). Step complete when all entities pass validation.
5. **Execute** -- Tabbed per-entity summary cards (4-item grid: Environment, Entity Type, Rows, Staging Table). Mapped Fields card (teal) lists all mapped field display names including field assignments with mode tags. Nullify card (purple) lists nullified field display names when applicable. XML Preview button with distinct button styling. Single Jira ticket field (applies to all). Submit All button processes entities sequentially. Per-tab success/failure indicators. Consolidated AR log auto-submits after all entities complete if Jira ticket provided.

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

**April 10, 2026 (TEST - Consolidated AR Log + import_as_user_name):**
- **Test 7 (Dirk):** Multi-entity (PHONE + CONSUMER_TAG) with Jira ticket. Both primary BDLs submitted successfully. Single consolidated AR log submitted covering both entities. DM attributed imports to actual user (dcota) via `import_as_user_name` header element instead of apiuser. Confirmed working across both entity types.

**April 15, 2026 (TEST - Per-Field Mode + Lookup Discovery):**
- **Test 8 (Dirk):** CONSUMER entity with `wrkgrp_shrt_nm` in all three modes (File, Blanket, Conditional). Staging, validation, and lookup all functional. 4-step lookup discovery correctly resolved `wrkgrp_shrt_nm` as a direct column match in the `wrkgrp` table (Step 1).
- **Test 9 (Dirk):** CONSUMER_TAG with From File mode -- tag values mapped from a file column instead of manual entry. Staging and validation functional.

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
- Field info modal shows display names in white, descriptions in smaller grey text, import guidance in yellow/amber italic (when populated)

### Multi-Entity Selection
- Entity cards are toggle-selectable (click to select/deselect) instead of single-select
- `selectedEntities[]` array holds all selected entities; `entityStates[]` array holds per-entity state
- Each entity state independently tracks: fields, columnMapping, assignments, fieldAssignments, stagingContext, stagedMapping, validationResult, validated flag
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
- FILE_MAPPED: full column mapping panels with drag-and-drop, per-field mode toggle on conditional-eligible fields
- FIXED_VALUE: assignment card model with File/Blanket/Conditional modes per card
- HYBRID: reserved for future -- may be unnecessary given per-field mode model handles all combinations natively

### Per-Field Mode Model (Implemented April 15)
- The three value assignment modes (From File, Blanket, Conditional) are a **per-field** decision, not an entity-level decision
- Any `is_conditional_eligible` field on any entity type supports all three modes:
  1. **From File** -- map to a source column (file already has the values) -- standard drag-drop on FILE_MAPPED, column selector on FIXED_VALUE
  2. **Blanket** -- enter one value applied to all rows
  3. **Conditional** -- vary by trigger column with per-value typeahead
- This makes the HYBRID `action_type` potentially unnecessary -- the per-field model handles all combinations:
  - FILE_MAPPED entity with conditional workgroup = consumer fields mapped from file, workgroup uses assignment card
  - FIXED_VALUE entity with tag from file = tag value mapped from a file column instead of entered manually
- The `action_type` on `Catalog_BDLFormatRegistry` determines the **default UI path** for the entity, not a rigid constraint
- FILE_MAPPED entities: fields default to target panel (File mode); conditional-eligible fields get mode toggle to override
- FIXED_VALUE entities: fields default to assignment card (Blanket mode); conditional-eligible fields get 3-way mode toggle
- Implementation: per-field mode selector on FILE_MAPPED target chips; 3-way toggle on FIXED_VALUE assignment cards
- First real-world use cases: CONSUMER entity with `wrkgrp_shrt_nm`; CONSUMER_TAG with `tag_shrt_nm` via From File mode

### 4-Step Lookup Column Discovery (Implemented April 15)
- Previous approach hardcoded `_val_txt` as the value column pattern -- failed for entity lookup tables (wrkgrp, tag, crdtr, etc.) where the element_name IS the column
- New universal resolution discovers the value column dynamically using catalog data (`element_name`, `lookup_table`) and INFORMATION_SCHEMA column inspection
- Resolution order (short-circuits at first match):
  1. **Direct match:** `element_name` exists as a column in the lookup table (e.g., `wrkgrp_shrt_nm` in `wrkgrp`, `tag_shrt_nm` in `tag`, `cntry_val_txt` in `Ref_cntry_cd`)
  2. **`*_val_txt` fallback:** first column matching pattern (e.g., `cnsmr_phn_typ_val_txt` → `phn_typ_val_txt`)
  3. **`*_shrt_nm` fallback:** first column matching pattern (e.g., `cnsmr_lst_wrkgrp_shrt_nm` → `wrkgrp_shrt_nm`)
  4. **`*_nm` fallback** (excluding `_shrt_nm`): first column matching pattern (e.g., `schdld_pymnt_instnc_prcssng_fee_typ_nm` → `fee_typ_nm`)
- Validated against all 52 distinct lookup tables across all 83 BDL entity types -- zero exceptions
- Table structure cached per-table; value column resolved per-element (same table may resolve differently for different elements)
- Applied to both validation endpoint (full value set for comparison) and typeahead endpoint (LIKE search with TOP 10)

### Fixed-Value Mapping UI
- Assignment card model with per-card mode selection
- Each card independently selects File, Blanket, or Conditional mode (3-way toggle when entity has conditional-eligible fields)
- File mode: source column dropdown for the conditional-eligible field; shared fields for non-varying fields
- Blanket mode: direct value entry fields for each non-identifier visible field
- Conditional mode: trigger column selector, unique value grid, per-value typeahead
- Lookup fields use debounced typeahead search (300ms) against DM reference tables via `/api/bdl-import/lookup-search`
- Typeahead uses the same 4-step column discovery as validation
- Suggestions show value and description side by side; results cached per element+search term
- Validate button enabled when identifier is selected and all required fields/modes are complete

### Fixed-Value Staging Pipeline
- Stage request sends `assignments` array with per-assignment mode, values, and file column references
- Server Path A: iterates file rows first, then assignments within each row (consumer-grouped ordering)
- Blanket assignments: fixed values inserted for every file row
- Conditional assignments: trigger column value looked up per row, mapped to output value, skipped if unmapped
- From File assignments: conditional field value read from specified file column index, skipped if empty, shared fields applied
- Mixed-path support: when assignments have different column structures, grouped by column list for efficient batching
- Validation runs normally against the staged data -- same validation infrastructure regardless of mode

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
- Field assignments and FIXED_VALUE assignments included in change detection for re-staging

### Cascading Validation
- Validation issues presented as accordion cards -- one expandable at a time
- Required empty and lookup invalid are actionable (fill/replace/skip controls)
- Max length and data type are informational only
- Auto re-validate fires after each fill/skip action
- Cascading effect: skipping rows for one field removes those rows from subsequent checks
- User interaction disabled during re-validate cycle
- Import guidance displayed as amber tip at top of validation card body when populated

### Consolidated AR Log (April 10)
- One AR log BDL file per batch execution, replacing the earlier per-entity pattern
- Built from first successful entity's staging table (identifiers consistent across aligned entities)
- AR message references all entity types in the batch (e.g., "SD-1234: PHONE, CONSUMER_TAG update via BDL Import")
- Dedicated endpoint `POST /api/bdl-import/execute-ar-log`
- `parent_log_ids` (VARCHAR(200)) stores comma-separated primary log_id values
- Auto-submitted by `executeSequential()` after all entities complete; no manual step required
- AR log failure rendered in unified results pane but does not block completion or promote eligibility
- Replaces the earlier per-entity AR log pattern where each entity generated its own companion file

### import_as_user_name (April 10)
- Added to XML header in both `Build-BDLXml` and `Build-ARLogXml`
- Passes authenticated CC user's AD username (domain prefix stripped)
- DM attributes imports to actual user instead of apiuser
- Falls back to apiuser silently if username not recognized by DM
- Confirmed working across PHONE and CONSUMER_TAG entity types

### BDL Permissions Admin Modal (April 10)
- Extends existing BDL Content Management admin modal with dual-mode UI
- Global Configuration mode: existing catalog editing behavior unchanged, plus import_guidance column
- Department Access mode: entity and field access management per department
- UPSERT via MERGE on AccessConfig and AccessFieldConfig
- Apps/Int department excluded from dropdown (admin tier bypass handles their access)
- Ungranted entities block field management (FK constraint on AccessFieldConfig.config_id)

### Import Guidance (April 10)
- `import_guidance VARCHAR(500)` column on `Catalog_BDLElementRegistry`
- Displayed in: field info modal, fixed-value mapping UI, mapping target chips, and validation card bodies (most important location)
- Yellow/amber (`#dcdcaa`) italic styling distinguishes from `field_description`
- Validation cards show guidance as a left-bordered tip at top of card body, before action controls
- Editable through admin catalog modal (Global Configuration mode)
- Populated over time by Matt as operational tips are identified

### Identifier Field Gating
- Mapping panels disabled and dimmed until identifier column is selected
- Red border when unselected, green border when confirmed
- Applies to both FILE_MAPPED and FIXED_VALUE entity types

### Promote to Production (Restored April 10)
- After successful non-PROD import (at least one entity succeeded), Promote to Production card appears below the unified results pane
- GlobalConfig-driven cooldown timer (`bdl_promote_cooldown_seconds`) counts down before enabling the card
- Card is interactive during countdown -- clicking flashes hint: "Please verify your results in the lower environment first"
- When timer expires, card shows "Ready" with green styling; clicking opens PROD advisory modal
- PROD advisory modal shows source environment, entity list with row counts, and production warning
- Confirming swaps `selectedEnvironment` to PROD, resets execution state (preserving staging data, mappings, alignment), resets `xmlPreviewLoaded`, and re-renders Step 5
- User gets full edit capability on the PROD summary (alignment, XML preview, Jira ticket, Submit All)
- Promote metadata (`promote_cooldown_seconds`, `prod_config_id`) captured from first successful API response

### Unified Execution Results (April 10)
- Per-entity result divs removed from individual tab content
- All execution results (primary BDLs + consolidated AR log) render in a unified results pane below the tabs
- Each result card includes entity name in title: "Phone — Submitted", "AR Log — Submitted"
- Results accumulate as `executeSequential()` processes each entity
- Pane appears automatically when first execution begins; hidden before that

### Row Count Alignment (April 10)
- Mismatch detection banner appears on Step 5 when multiple entities have different active row counts AND at least one FIXED_VALUE/HYBRID entity exists
- Alignment only applies to FIXED_VALUE/HYBRID entities -- FILE_MAPPED entities are independent alignment sources
- "Align Row Counts" button opens a modal with per-entity dropdowns listing FILE_MAPPED entities as alignment targets
- Alignment joins staging tables on shared identifier column (`cnsmr_idntfr_agncy_id` or `cnsmr_accnt_idntfr_agncy_id`), skips rows in target that are skipped in source
- "Undo" per entity in the modal resets all `_skip = 0` on that entity's staging table
- Step 5 re-renders after alignment with updated counts in summary cards
- Design principle: FILE_MAPPED = independent ("load this data"), FIXED_VALUE = derivative ("apply this to those records")

### XML Preview per Entity Tab (April 10)
- Single-click "Preview XML" header in each entity tab on Step 5
- First click expands section and fires `/api/bdl-import/build-preview` API call
- Subsequent clicks toggle visibility without re-fetching (uses `xmlPreviewLoaded` flag on entity state)
- XML rendered with syntax highlighting (declaration, tags, attributes, values via CSS classes)
- Copy button uses `document.execCommand('copy')` fallback -- `navigator.clipboard` does not work in Pode-served environment
- Preview truncated at 100KB with note; full file size shown in metadata

### Environment Badge (April 10)
- Persistent badge in the far left of the stepper bar showing the selected environment (TEST, STAGE, PROD)
- Appears after Step 1 environment selection, updates on Promote to Production
- Color palette: TEST = yellow (`#dcdcaa`), STAGE = orange (`#ce9178`), PROD = red (`#ef4444`)
- PROD environment card border and selected name color also changed from green to red to match badge
- Badge container in route HTML (`BDLImport.ps1`), populated by `updateEnvBadge()` in JS

### Styled Modal System
- All native dialogs replaced with `showAlert()`/`showConfirm()` from `engine-events.js`
- BDL Import is the reference implementation
- Development Guidelines Section 5.10 updated with shared modal function documentation and BOLO for legacy native dialogs on other pages

### Guide Panel
- Compact tip panel in upper right column
- Content updates automatically based on current step (5 steps)

### Server Configuration
- `tools_enabled` on ServerRegistry = master switch for Tools server participation
- `api_base_url` and `is_api_primary` on `dbo.ServerRegistry` = API targeting (single source of truth for all server knowledge, deployed April 13)
- `Tools.EnvironmentConfig` = per-environment operational config (file paths, db_instance, pipeline folders)
- `db_instance` stores the database server/listener per environment

### DM API Authentication
- Credentials stored in `dbo.Credentials` under `ServiceName = 'DM_REST_API'`
- Two-tier encryption: master passphrase -> service passphrase -> credential values
- `AuthHeader` stores complete `Basic <base64>` string

### XML Construction
- XML built entirely from catalog data via `Build-BDLXml` in `xFACts-Helpers.psm1`
- File extension is `.txt`
- BOM-less UTF-8 encoding
- `import_as_user_name` header element passes authenticated CC user's AD username to DM
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
- Field assignment columns (per-field mode overrides) added via ALTER TABLE with blanket UPDATE or per-trigger-value UPDATEs
- Re-staging drops old table atomically via `drop_existing` parameter

### Import Lifecycle
- Status progression: BUILDING -> REGISTERED -> SUBMITTED / FAILED
- Column mapping captured as JSON in `BDL_ImportLog.column_mapping`
- Completion tracking deferred to BatchOps BDL monitoring collector

### RBAC Middleware: Department-Scoped Roles on Shared Pages
- Fix: explicit permission rows always honored regardless of department scope

### Excel Date Formatting (April 11)
- `cellDates: true` option added to SheetJS `XLSX.read()` calls to parse date serial numbers as JS Date objects
- `excelCellValue()` helper detects date cells (`cell.t === 'd'`) and formats as `YYYY-MM-DD` (ISO 8601) with zero-padded month/day and 4-digit year
- Non-date cells use `cell.w` (Excel's formatted text) when available, falling back to `cell.v` (raw value)
- Applies to both preview parsing (`parseExcelPreview`) and full data parsing (`parseExcelAllRows`)
- BDL date/datetime fields require either `YYYY-MM-DD` or `MM/DD/YYYY` format; ISO chosen as safest for XML

### Nullify in Mapping Step (April 11)
- Nullify controls placed in the mapping step (Step 4) rather than the validation screen
- Rationale: nullify is a mapping-level decision ("what should happen to this field"), not a validation-level decision
- Nullify fields preserved through re-validation since they're part of the mapping, not validation state
- Nullify badge not shown on conditional-eligible fields (they use the mode toggle instead)
- Purple accent color (`#c586c0`) used consistently for all nullify UI elements

### Record-Level Auto-Nullify (April 11)
- Empty values in mapped columns are automatically nullified at XML build time for entities with `has_nullify_fields = 1`
- Rationale: if a column is explicitly mapped, the source file is the source of truth for that field -- empty means "clear it," not "leave it alone." Silent-skip only applies to unmapped fields where omission means "not touching this field."
- Mimics Matt's Access Toolkit behavior where pasting a NULL into a mapped field triggered nullification
- Non-nullifiable fields (`is_not_nullifiable = 1`) are excluded -- empty values still silently skipped
- No UI change required -- implemented entirely in `Build-BDLXml`

### Identifier Handling
- Consumer-level: `cnsmr_idntfr_agncy_id`
- Account-level: `cnsmr_accnt_idntfr_agncy_id`
- Only agncy_id works reliably per Matt
- Identifier must be selected before mapping is enabled

### ActionAuditLog Redesign (April 13)
- Redesigned from field-level config change tracking to universal user action audit trail
- New structure: `page_route`, `action_type`, `action_summary`, `environment`, `result`, `error_detail`, `executed_by`, `executed_dttm`
- `action_summary` is a human-readable string built by calling code
- Serves dual purpose: audit trail and cooldown enforcement for throttled operations
- action_type values: CONFIG_CHANGE, SCHEDULE_CHANGE, JOB_TRIGGER, BDL_IMPORT, ACCESS_CHANGE, ALERT_RESEND
- 91 legacy rows migrated
- All existing writers updated: Admin-API.ps1 and JBossMonitoring-API.ps1

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

### AR Log Scope (April 10)
18. **AR log consolidation:** Single AR log per batch execution is sufficient. Per-entity pattern was unnecessary overhead. Implemented as consolidated pattern.

---

## DM API Integration

### Server Routing
| Environment | File Target (dmfs) | API Target (Primary) | DB Instance |
|-------------|-------------------|---------------------|-------------|
| TEST | DM-TEST-APP | DM-TEST-APP | DM-TEST-APP |
| STAGE | DM-STAGE-APP3 | DM-STAGE-APP | AVG-STAGE-LSNR |
| PROD | DM-PROD-APP3 | DM-PROD-APP | AVG-PROD-LSNR |

**API URL source:** `dbo.ServerRegistry WHERE is_api_primary = 1 AND tools_enabled = 1` (deployed April 13). File paths and db_instance from `Tools.EnvironmentConfig`.

**All app servers per environment (for multi-server operations like Refresh Drools):**
| Environment | App Servers | Primary |
|-------------|-------------|---------|
| PROD | DM-PROD-APP, DM-PROD-APP2, DM-PROD-APP3 | DM-PROD-APP |
| STAGE | DM-STAGE-APP, DM-STAGE-APP2, DM-STAGE-APP3 | DM-STAGE-APP |
| TEST | DM-TEST-APP | DM-TEST-APP |

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
    <import_as_user_name>dcota</import_as_user_name>
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
| GET | `/api/bdl-import/environments` | Available environments from EnvironmentConfig |
| GET | `/api/bdl-import/entities` | Available entity types with `action_type`, `entity_key` (RBAC + is_active filtered) |
| GET | `/api/bdl-import/entity-fields?entity_type=X` | BDL fields for an entity (admin: all visible; dept: AccessFieldConfig whitelist). Includes `import_guidance`, `is_conditional_eligible`. |
| GET | `/api/bdl-import/lookup-search` | Typeahead search against DM lookup tables. 4-step column discovery. Params: lookup_table, element_name, search, config_id. |
| POST | `/api/bdl-import/stage` | Create staging table, insert rows. Path A: assignments-based expansion (file/blanket/conditional modes). Path B: file-mapped with optional fixed_values and field_assignments. |
| POST | `/api/bdl-import/validate` | Read staging table + fetch lookups from DM with 4-step column discovery (repeatable) |
| POST | `/api/bdl-import/replace-values` | Mass-replace values in staging table column |
| POST | `/api/bdl-import/skip-rows` | Mark rows as skipped in staging table |
| POST | `/api/bdl-import/align-rows` | Align target staging table skip set to source |
| POST | `/api/bdl-import/reset-alignment` | Reset all skipped rows in a staging table to active |
| POST | `/api/bdl-import/set-nullify-fields` | Set blanket nullify fields on staging table |
| GET | `/api/bdl-import/staging-cleanup` | Check for expired staging tables (>48 hours) |
| POST | `/api/bdl-import/staging-cleanup` | Drop expired staging tables |
| GET | `/api/bdl-import/history` | Recent import history from BDL_ImportLog |
| POST | `/api/bdl-import/build-preview` | Build XML and return for preview |
| POST | `/api/bdl-import/execute` | Full pipeline: build XML -> write -> register -> trigger (primary BDL only) |
| POST | `/api/bdl-import/execute-ar-log` | Consolidated AR log: build + register + trigger for all entities in a batch |
| GET | `/api/bdl-import/templates?entity_type=X` | List saved templates for an entity type |
| POST | `/api/bdl-import/templates` | Save a new template |
| PUT | `/api/bdl-import/templates/:id` | Update a template (creator or admin only) |
| DELETE | `/api/bdl-import/templates/:id` | Deactivate a template (creator or admin only) |
| GET | `/api/apps-int/departments` | Active departments for access mode dropdown (excludes Apps/Int) |
| GET | `/api/apps-int/bdl-access?department=X` | Format list with per-department access status and field counts |
| GET | `/api/apps-int/bdl-field-access?config_id=X` | Element list with per-field granted status |
| POST | `/api/apps-int/bdl-access/toggle` | UPSERT entity access grant for a department |
| POST | `/api/apps-int/bdl-field-access/toggle` | UPSERT field access grant for a department |

---

## Next Steps

### Tag Entity Filtering (Priority: Next session)

**Context:** CONSUMER_TAG and ACCOUNT_TAG entities need to restrict typeahead and validation lookup results to only tags associated with the correct entity level. Without filtering, a user could accidentally select an account-level tag for a consumer import, which would fail or produce incorrect results in DM.

**Filter chain:** `tag` → `tag_typ_id` → `tag_typ.tag_typ_id` → `tag_typ.tag_typ_entty_assctn_cd` → `ref_entty_assctn_cd`
- CONSUMER_TAG: `tag_shrt_nm FROM tag WHERE tag_typ_id IN (SELECT tag_typ_id FROM tag_typ WHERE tag_typ_entty_assctn_cd = 2)`
- ACCOUNT_TAG: `tag_shrt_nm FROM tag WHERE tag_typ_id IN (SELECT tag_typ_id FROM tag_typ WHERE tag_typ_entty_assctn_cd = 3)`

**Implementation approach:**
- Add entity-level context to lookup-search and validate calls when lookup_table is `tag`
- The entity_type (CONSUMER_TAG vs ACCOUNT_TAG) maps to entty_assctn_cd (2 vs 3)
- Filter applied as JOIN or WHERE subquery on the lookup query
- May need a catalog-driven approach (e.g., `lookup_filter` column on element registry) rather than hardcoding tag-specific logic, to handle similar cases on future entity types

### BDL Import User Guide Update (Priority: Next session — BI release imminent)

**Context:** BI team is being onboarded to use BDL Import for production workflows. The existing `bdl-import-guide.html` covers the original 5-step wizard but does not document the per-field mode selector, From File mode, conditional assignments, or the 3-way toggle. Guide needs to be updated before official BI team release.

**Scope:**
- Update Step 4 (Map & Validate) section to cover the 3-way mode toggle on both FILE_MAPPED and FIXED_VALUE entities
- Add visual mockups or descriptions for File, Blanket, and Conditional modes
- Document the Field Assignments section that appears below mapping panels
- Add section on From File mode for tag imports
- Review and update all existing step descriptions for accuracy

### DM Job Triggers (Apps/Int Page) — R1-R4 COMPLETE

R1 (Refresh Drools), R2 (Release Notices), R3 (Balance Sync), and R4 (Request Validation) are deployed and operational on the Applications & Integration page. Uses ServerRegistry for API URLs, ActionAuditLog for audit + cooldown enforcement. Environment selection explicit via modal.

**Remaining:**
| # | Name | DM Endpoint | Server Target | Cooldown |
|---|------|-------------|---------------|----------|
| R5 | Launch Job (generic) | POST `/jobs/{job_name}/execute` | Single (primary) | None |

- R5 (generic launcher) should be admin-only -- freeform job name input

### Immediate (Pre-existing)

1. **Execution progress indicator** -- Re-wire the step-through progress display (building XML -> registering -> submitting) into the unified results pane. CSS classes exist (`.progress-steps`, `.progress-active`, `.progress-complete`). Visual polish item. May not be needed -- BatchOps BDL collector already shows processing status on Batch Monitoring page. Evaluate whether this adds value.

2. **`value_changes` column on BDL_ImportLog** -- Verify whether the replace-values and fill-empty endpoints are actually populating this column. If not, wire it in. Designed as batch-level replacement audit trail but may not be connected.

3. **Record-level import audit table** -- Pending Matt's input on his current tracking pattern. Single table design to accommodate all entity types using JSON payload per record. Volume concern for large imports (250K rows). Deferred pending clarification on Matt's requirements and scope.

### Nullify Fields (Implemented April 11)

Supports explicit nullification of field values in DM via the `<nullify_fields>` XML block. Two complementary mechanisms:

**Blanket Nullify (UI-driven, mapping step):**
- Nullify badge (∅) appears on each eligible target field chip in the BDL Fields panel during mapping (not shown on conditional-eligible fields which use the mode toggle instead)
- Eligibility: entity has `has_nullify_fields = 1`, field has `is_not_nullifiable = 0`, field is not `is_import_required`, field is not `is_conditional_eligible`
- Clicking the badge moves the field from the target panel into the Mapped section as "∅ Nullify → Field Name" with ✕ to undo
- Tracked in `state.nullifyFields[]` during mapping, preserved through re-validation
- Persisted to staging table `_nullify_fields` column (VARCHAR(MAX), comma-separated) via `POST /api/bdl-import/set-nullify-fields` on entity advance or step transition
- Field info modal (entity cards) also displays ∅ icon for nullifiable fields with hover tooltip

**Record-Level Nullify (automatic, Build-BDLXml):**
- When a mapped column has an empty/NULL value for a row and the entity supports nullify, that field is automatically added to the record's nullify block instead of being silently omitted
- Non-nullifiable fields (`is_not_nullifiable = 1`) are excluded -- empty values still silently skipped for those
- `Build-BDLXml` queries `Catalog_BDLElementRegistry` for non-nullifiable field set at XML build time
- Mimics Matt's Access Toolkit behavior: pasting a NULL into a field triggers nullification for that record

**Combined behavior per row:**
- Blanket nullify fields (from `_nullify_fields` column) + record-level nullify fields (empty mapped columns) are merged into a single `<nullify_fields>` block per record
- Duplicates excluded (blanket already in list not re-added from record-level detection)
- Data elements loop unchanged -- still skips empty values (they're captured as nullify entries instead)

**Execute Summary:**
- Step 5 summary grid: 4 items (Environment, Entity Type, Rows, Staging Table)
- Mapped Fields card (teal accent `#4ec9b0`) lists all mapped field display names including field assignments with mode tags
- Nullify card (purple accent `#c586c0`) lists nullified field display names (only when applicable)
- Same cards shown on Step 4 validated/complete screen for consistency
- XML Preview rendered as a distinct button rather than clickable header for visibility

### Follow-Up Items

- **HYBRID action_type evaluation** -- Per-field mode model (April 15) may make HYBRID unnecessary as a separate action_type. The per-field model handles all combinations natively. Decision deferred until more entity types are onboarded.
- **Same source column mapped to multiple BDLs** -- Pending Brandon's input on whether this is a real scenario.
- **Reset validation skips for mapped entities** -- Currently no mechanism to undo validation-phase skips on FILE_MAPPED entities without re-running validation from scratch. Future enhancement.
- **Step guide text refinement** -- Right-column guidance for each step.
- **Template UX refinement** -- User feedback on template workflow.
- **Typeahead lookup column discovery** -- Now uses 4-step dynamic resolution. No further hardcoded patterns needed.
- **Wrapper element selection** -- Most entity types appear under both `consumer_operational_transaction_data` and `account_operational_transaction_data` in the XSD. Current code takes the first match from the catalog. This works for PHONE and CONSUMER_TAG but may need a `wrapper_format_id` column on `Catalog_BDLFormatRegistry` if future entities require a specific wrapper.
- **`custom_properties` XML block** -- Currently included as an empty `<custom_property/>` element. May not be needed; successful third-party tag imports omit it entirely. Consider removing.
- **Record-level import audit table** -- Pending Matt's input on current tracking pattern. Single table design to accommodate all entity types. Volume concern for large imports (250K rows). Deferred to future session.
- **`value_changes` population gap** -- Verify and wire in if not connected.
- **GlobalConfig history UI** -- Admin-API endpoint updated for new ActionAuditLog columns. May need minor admin.js adjustment if a history display exists or is added.

### Phase 2

- Import history view on the BDL Import page
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
One row per element within each entity type. Child table via `format_id` FK. Key columns: `element_name`, `display_name`, `data_type`, `max_length`, `table_column`, `lookup_table`, `is_not_nullifiable`, `is_primary_id`, `is_visible`, `is_import_required`, `is_conditional_eligible`, `field_description`, `import_guidance`.

### Three "Required" Columns (Disambiguation)
- `is_required` -- XSD `minOccurs`. Almost always 0. Not useful for import decisions.
- `is_not_nullifiable` -- From Excel spec. Means "cannot be included in nullify_fields." Also controls Skip button visibility on required empty fields.
- `is_import_required` -- Practical requirement from operational experience. Set by Matt. **This is the only flag used for required field validation and hard blocks.**

### Lookup Table Discovery Pattern (4-Step — April 15)
For fields with `lookup_table` populated, the typeahead and validation endpoints discover the value column dynamically:
1. **Direct match:** `element_name` is a column in the lookup table (e.g., `wrkgrp_shrt_nm` in `wrkgrp`)
2. **`*_val_txt` fallback:** first column matching pattern (e.g., `phn_typ_val_txt` in `Ref_phn_typ_cd`)
3. **`*_shrt_nm` fallback:** first column matching pattern (e.g., `wrkgrp_shrt_nm` when element is `cnsmr_lst_wrkgrp_shrt_nm`)
4. **`*_nm` fallback** (excluding `_shrt_nm`): first column matching pattern (e.g., `fee_typ_nm` in `fee_typ`)
- **Active flag:** First column matching `*_actv_flg` pattern
- **Description:** First column matching `*_nm` (excluding resolved value column), then `*_dscrptn_txt`

### Tag Type Filtering (Planned)
Tags in DM are entity-scoped via `tag_typ.tag_typ_entty_assctn_cd`:
- Consumer tags: `tag_typ_entty_assctn_cd = 2` (maps to `ref_entty_assctn_cd` CONSUMER)
- Account tags: `tag_typ_entty_assctn_cd = 3` (maps to `ref_entty_assctn_cd` CONSUMERACCOUNT)
- Filter chain: `tag.tag_typ_id` → `tag_typ.tag_typ_entty_assctn_cd`
- Applied to CONSUMER_TAG and ACCOUNT_TAG entities to prevent cross-level tag selection

---

## Database Object Inventory

### Tools.Operations Component
| Object | Type | Description |
|--------|------|-------------|
| EnvironmentConfig | Table | Per-environment DM configuration (file paths, db_instance) |
| AccessConfig | Table | Department-scoped tool/entity access control |
| AccessFieldConfig | Table | Field-level whitelist, child of AccessConfig |
| BDL_ImportLog | Table | Import execution audit trail (incl. parent_log_ids for consolidated AR log linking) |
| BDL_ImportTemplate | Table | Saved column mapping templates |

### Tools.Operations Component (BDL Import CC Files)
| Object | Type | Description |
|--------|------|-------------|
| BDLImport.ps1 | Route | BDL Import CC page route (5-step layout) |
| BDLImport-API.ps1 | API | BDL Import CC API endpoints (incl. template CRUD, consolidated AR log, assignments-based staging with file/blanket/conditional modes, per-field assignments, 4-step lookup discovery, set-nullify-fields) |
| bdl-import.js | JavaScript | BDL Import CC client-side logic (multi-entity, per-entity state, multi-assignment cards with file/blanket/conditional mode, per-field mode selector on FILE_MAPPED entities, typeahead, entity grouping, consolidated AR log, nullify badge in mapping, Excel date formatting) |
| bdl-import.css | CSS | BDL Import CC styles (incl. assignment card, trigger grid, mode toggle, per-field mode toggle, field assignment cards) |

### ControlCenter.Shared Component
| Object | Type | Description |
|--------|------|-------------|
| xFACts-Helpers.psm1 | Module | Shared helpers (Invoke-XFActsNonQuery, Build-BDLXml with blanket + record-level nullify, Build-ARLogXml, Get-ServiceCredentials) |

### DeptOps.ApplicationsIntegration Component
| Object | Type | Description |
|--------|------|-------------|
| ApplicationsIntegration.ps1 | Route | Apps/Int CC page route (admin modal HTML with mode selector) |
| ApplicationsIntegration-API.ps1 | API | Apps/Int CC API endpoints (BDL catalog management, format update, department access management) |
| applications-integration.js | JavaScript | Apps/Int CC client-side logic (BdlCatalog module with Global/Department modes) |
| applications-integration.css | CSS | Apps/Int CC styles (catalog modal, badges, mode selector, department access styling) |

### Documentation.Site Component
| Object | Type | Description |
|--------|------|-------------|
| bdl-import-guide.html | HTML | BDL Import user guide — standalone step-by-step walkthrough with visual mockups (update pending for per-field mode and From File features) |

### Credential Infrastructure
| Object | Location | Description |
|--------|----------|-------------|
| DM_REST_API | dbo.CredentialServices | Service registration for DM REST API |
| Username | dbo.Credentials | DM API username (apiuser), encrypted |
| Password | dbo.Credentials | DM API password, encrypted |
| AuthHeader | dbo.Credentials | Complete Basic auth header string, encrypted |

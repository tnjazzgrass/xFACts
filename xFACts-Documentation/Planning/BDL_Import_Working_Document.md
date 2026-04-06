# BDL Import Module -- Working Document

**Status:** In development -- Steps 1-6 functional, end-to-end tested on TEST and PROD  
**Audience:** Dirk, Matt, Brandon, Claude  
**Last Updated:** April 6, 2026  
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
- `Tools.BDL_ImportLog` -- import execution audit trail with lifecycle status tracking, `column_mapping` JSON, `value_changes` column for replacement audit, `file_registry_id` from DM API, `parent_log_id` self-referential FK for linking AR log companion rows to their parent primary import, and `staging_table` column for test-to-prod correlation tracking
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

**AR Log (Jira Ticket Link) -- fully operational:**
- `Build-ARLogXml` function in `xFACts-Helpers.psm1` -- constructs a `CONSUMER_ACCOUNT_AR_LOG` BDL XML from staging table data, creating one AR log entry per non-skipped row
- Uses CC/CC (clerical comment) action/result codes across all entity types -- internal codes that do not appear on client export notes
- Mirrors Matt's legacy VBA companion AR Event file pattern exactly
- Identifier element auto-detected: `cnsmr_idntfr_agncy_id` for consumer-level entities, `cnsmr_accnt_idntfr_agncy_id` for account-level
- `cnsmr_accnt_ar_log_crt_usr_nm` set to the logged-in Windows username (not the API service account)
- AR log BDL is built and submitted as a separate file through the full register -> import cycle after the primary BDL succeeds
- AR log failure does NOT roll back the primary import
- AR log row in `BDL_ImportLog` uses `parent_log_id` to link back to the primary import row
- Default AR message format: `"{ticket}: {entity_type} update via BDL Import"` -- editable by the user on Step 6
- Jira ticket field and AR message field are optional on Step 6; if left blank, no AR log is generated (current behavior preserved)

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
- `Build-ARLogXml` added to `xFACts-Helpers.psm1` -- constructs CONSUMER_ACCOUNT_AR_LOG BDL XML for Jira ticket linking
- `Get-ServiceCredentials` in `xFACts-Helpers.psm1` -- two-tier decryption for DM API credentials

**Control Center pages:**
- `BDLImport.ps1` / `BDLImport-API.ps1` / `bdl-import.js` / `bdl-import.css` -- BDL Import wizard page
- Two-column layout: 65% left (stepper bar + action panels) / 35% right (compact step guide + template section)
- Shared `engine-events.css` linked for slideout panel pattern, shared visual standards, and styled modal system (`xf-modal-*` classes)
- Shared `engine-events.js` linked for `showAlert()` and `showConfirm()` styled modal functions -- BDL Import is the reference implementation; no native `alert()` or `confirm()` calls remain on this page
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

1. **Select Environment** -- Cards for TEST, STAGE, PROD loaded from `Tools.ServerConfig`. Environment-specific accent colors. All environments unlocked. Selecting PROD shows a styled advisory modal recommending test environment validation first, with Go Back / Continue to Production buttons.
2. **Select Entity Type** -- Grid of available entities filtered by `is_active = 1` and RBAC tier/department. Searchable. Admin sees all active; department users see only AccessConfig-granted entities. Template count preview shown in right column when entity is selected.
3. **Upload File** -- Drag-and-drop or browse. CSV, TXT, XLSX, XLS supported via client-side parsing (SheetJS for Excel). Preview renders inside the drop zone replacing the upload prompt. Row count warning above 250K.
4. **Map Columns** -- Identifier field (consumer or account agency ID) must be selected first -- mapping panels are disabled with red border highlight until identifier is chosen. Once selected, identifier border turns green and two-column layout (Source | BDL Fields) activates with click-to-pair and drag-and-drop. Mapped pairs displayed in a spanning section below. Display names shown when populated. Templates can be loaded from the right column to pre-populate mappings. "Save Current Mapping as Template" button available when mappings exist.
5. **Validate** -- Two-phase: stage (one-time) then validate (repeatable with cascading re-validate).
   - **Stage:** Reads full file, creates `Staging.BDL_{entity}_{user}_{timestamp}` table. Supports `drop_existing` parameter for re-staging when mapping changes on back navigation.
   - **Validate:** Accordion-style issue cards. Actionable issues (required empty, invalid lookup) shown as collapsed cards -- click to expand and resolve. One card expandable at a time. Required empty: fill or skip triggers immediate re-validate. Lookup invalid: all unique values resolved per element, then auto re-validate. Cascading effect: skipping rows for one field removes those rows from subsequent lookup/required checks.
   - Informational warnings (max length, data type) shown in separate collapsible section with no action controls.
   - Next button muted/gray when issues exist, colored blue when validation passes.
   - **Re-validate button removed** -- cascading auto-revalidation after each fill/skip action renders the manual button obsolete.
   - **Staging cleanup:** Banner on page load if tables older than 48 hours found. One-click cleanup drops them.
6. **Review & Execute** -- Summary display showing environment, entity type, source file, row count (reflects non-skipped rows with skipped count annotation), mapped fields, and staging table. Optional Jira ticket input with editable AR message (defaults to `"{ticket}: {ENTITY_TYPE} update via BDL Import"`). Collapsible column mapping reference. Collapsible XML preview with syntax highlighting -- auto-loads on first expand (no separate "Load Preview" button), with Copy to Clipboard button for external review. Styled confirmation modal (environment-aware: danger button for PROD, standard for non-PROD) replaces native confirm dialog. Progress visualization. Success/failure result cards. When a Jira ticket is provided, a companion AR log BDL is built and submitted after the primary import succeeds, with its own result card shown below the primary result. Back button hidden after successful submission. Promote to Production card appears after successful non-PROD imports (see Architecture Decisions).

### End-to-End Test Results

**April 3, 2026 (TEST):**
- **Test 1 (Dirk):** 24-row PHONE file -> staged, validated, XML built, registered with DM (fileRegistryId 304146), import triggered, DM processed successfully. All 24 phone records confirmed in crs5_oltp.
- **Test 2 (Brandon):** ~5000-row PHONE file with ~1100 rows missing phone numbers -> staged, validated with skip, quality score filled, import submitted successfully.

**April 4, 2026 (PROD):**
- **Test 3 (Dirk):** PHONE BDL import into PRODUCTION -- 100% success. First production import via xFACts.

**April 4, 2026 (TEST - AR Log):**
- **Test 4 (Dirk):** 395-row file with Jira ticket link -> primary BDL submitted successfully, AR log companion BDL submitted successfully. Both files processed in DM with 395 records each.

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
- Manual re-validate button removed -- cascading auto-revalidation makes it obsolete

### AR Log Companion Pattern
- When a Jira ticket is provided during import execution, the system generates two separate BDL files: the primary data file and a companion CONSUMER_ACCOUNT_AR_LOG file
- The AR log creates a clerical comment (CC/CC action/result codes) on each imported record, linking it back to the originating Jira ticket via `cnsmr_accnt_ar_mssg_txt`
- This mirrors the legacy VBA toolkit pattern where update operations (phone, address, account, consumer) always produced a companion AR Event file
- CC/CC codes are internal clerical comments that do not appear on client export notes files; CO/CO is the standard comment code that does -- CC/CC is used across all entity types for BDL Import
- The two files are registered and imported through the DM API independently as separate BDL imports
- `parent_log_id` on `BDL_ImportLog` links the AR log row to its parent primary import row -- this is an internal xFACts relationship for audit trail purposes; on the DM side each file has its own `file_registry_id` and processes independently
- AR log failure does not roll back the primary import -- the primary data is already in DM
- `cnsmr_accnt_ar_log_crt_usr_nm` is set to the logged-in Windows username, providing visibility into who ran the BDL (vs. the API service account `apiuser` that appears on the import itself)
- Default message format: `"{ticket}: {ENTITY_TYPE} update via BDL Import"` -- editable by the user before submission

### Identifier Field Gating
- Mapping panels (source columns, BDL fields, mapped pairs) are disabled and dimmed until the identifier column is selected
- Identifier section has red border when unselected, green border when confirmed
- Centered overlay message "Select the identifier column above to begin mapping" shown on dimmed panels
- Click, drag, and drop interactions blocked via `isMappingDisabled()` guard on all interaction handlers

### Promote to Production
- After a successful non-PROD import, a Promote to Production card appears on Step 6 with a GlobalConfig-driven countdown timer (`bdl_promote_cooldown_seconds` = 120 seconds, module `Tools`, category `Operations`)
- During countdown: card shows timer in monospaced font, clicking shows informational flash message encouraging data verification in DM
- After countdown expires: card transitions to "Ready" state with teal accent, clicking opens a styled confirmation modal with danger button
- On confirm: validates staging table still exists, switches `selectedEnvironment` to PROD, re-renders Step 6 with PROD targeting, Jira ticket fields pre-populated from the test run (editable)
- Data source: rebuilds XML from existing staging table -- does NOT re-read the original file
- If staging table expired: shows styled alert and redirects to Step 1
- Test-to-prod correlation: `staging_table` column on `BDL_ImportLog` tracks the relationship -- same staging table name appearing on TEST and PROD rows indicates the tested-first path
- `parent_log_id` is NOT for test-to-prod linking -- it links AR log companion rows to their parent primary import only
- API returns `promote_cooldown_seconds` and `prod_config_id` in the execute response for non-PROD environments

### Styled Modal System
- All native `alert()` and `confirm()` dialogs replaced with shared styled modals from `engine-events.js` (`showAlert()` and `showConfirm()`)
- CSS classes use `xf-modal-*` prefix, defined in `engine-events.css` with self-contained `xfModalFadeIn` animation
- `showAlert()` returns a Promise (resolves on OK click); `showConfirm()` returns a Promise resolving true/false
- Options: `title`, `icon` (HTML entity), `iconColor`, `buttonLabel`/`confirmLabel`/`cancelLabel`, `confirmClass` (supports `xf-modal-btn-danger` for destructive actions), `html` (boolean for rich HTML body content)
- `_escapeModalText()` private helper keeps the shared module self-contained (no dependency on page-specific `escapeHtml`)
- BDL Import is the reference implementation -- all other CC pages should migrate to this pattern as they are touched
- Development Guidelines should be updated to prohibit native `alert()`, `confirm()`, and `prompt()` on all CC pages

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

### communication_reference_id_txt Header Element
- Present in Matt's VBA for some entity types (PostPhnUpdts, PostAddrUpdts, PostAccntUpdts, PostCnsmrUpdts) but not others (PostAccntTags, PostCnsmrTags, PostRegFUDPs)
- Always hardcoded to `"Organization"` in the VBA
- PHONE import into PROD succeeded without it -- appears to be optional/informational
- **Decision:** Not included in xFACts XML output. If DM requires it for specific entity types in the future, it can be added as a catalog-driven header element.

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
- Import completion tracking (processed count, error count, DM status) is deferred to the BatchOps BDL monitoring collector -- see Next Steps

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
| GET | `/api/bdl-import/history` | Recent import history from BDL_ImportLog (includes parent_log_id) |
| POST | `/api/bdl-import/build-preview` | Build XML and return for preview (no file write or API calls) |
| POST | `/api/bdl-import/execute` | Full pipeline: build XML -> write to dmfs -> register -> trigger import. Optionally builds and submits companion AR log BDL when `jira_ticket` is provided. |
| GET | `/api/bdl-import/templates?entity_type=X` | List saved templates for an entity type |
| POST | `/api/bdl-import/templates` | Save a new template (duplicate name check) |
| PUT | `/api/bdl-import/templates/:id` | Update a template (creator or admin only) |
| DELETE | `/api/bdl-import/templates/:id` | Deactivate a template (creator or admin only) |

---

## Next Steps

### Immediate (Next Session)

1. **Development Guidelines update** -- Add prohibition on native `alert()`, `confirm()`, and `prompt()` across all CC pages (Section 5.10 Modals and Slideouts area). Reference BDL Import as the implementation model for the shared `showAlert()`/`showConfirm()` pattern.

2. **Step guide text refinement** -- Update the right-column guidance text for each step based on user feedback. Content is in `BDLImport.ps1` HTML.

3. **Template UX refinement** -- Gather user feedback on the template workflow (browse, preview, apply, save). Iterate on visual design and interaction patterns as needed.

4. **Version bumps** -- Deferred from April 6 session (see Outstanding Items below).

### Deferred Items (from April 6 session)

- **Template save/recall UI/API** -- Save current mapping as named template; recall and apply in future sessions
- **Guide panel redesign** -- Right-column step guidance content refresh
- **Back-button mapping preservation** -- Mapping state preserved on back navigation but dropdown selections may need attention
- **Cascading validation after skip/fill** -- Works but edge cases may exist with complex multi-field skip scenarios
- **`communication_reference_id_txt` header verification** -- Confirm with Matt whether any entity types require this header element
- **Brandon WebSocket 1006 closure** -- Investigate intermittent WebSocket closure on BDL Import page (may be related to long-running staging operations)

### Phase 2

- Import history view on the BDL Import page
- Admin UI for AccessFieldConfig management
- Admin UI for `is_active` toggle on format tables
- `display_name` enrichment across additional entity elements
- Staging table resume/review capability
- Post-import staging table viewer
- **BatchOps BDL monitoring collector** -- Pulls BDL processing results from DM's logging tables (file_registry tables, processing status, record counts, errors). Writes completion status back to `Tools.BDL_ImportLog` via `file_registry_id` join. This is already on the BatchOps roadmap as the final monitoring component -- building it also solves the BDL Import completion tracking gap. Cross-module: collector lives in BatchOps, write-back targets Tools schema.

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
| BDL_ImportLog | Table | Import execution audit trail (incl. parent_log_id for AR log linking) |
| BDL_ImportTemplate | Table | Saved column mapping templates (incl. description column) |
| BDLImport.ps1 | Route | BDL Import CC page route (two-column layout) |
| BDLImport-API.ps1 | API | BDL Import CC API endpoints (incl. template CRUD, AR log execute) |
| bdl-import.js | JavaScript | BDL Import CC client-side logic |
| bdl-import.css | CSS | BDL Import CC styles |

### ControlCenter.Shared Component
| Object | Type | Description |
|--------|------|-------------|
| xFACts-Helpers.psm1 | Module | Shared helper functions (incl. Invoke-XFActsNonQuery, Build-BDLXml, Build-ARLogXml, Get-ServiceCredentials) |

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

**DDL deployed this session (April 6):**
- `ALTER TABLE Tools.BDL_ImportLog ADD staging_table VARCHAR(200) NULL` -- test-to-prod correlation tracking
- `ALTER TABLE dbo.ServerRegistry ADD CONSTRAINT CK_ServerRegistry_environment_is_active CHECK (environment = 'PROD' OR is_active = 0)` -- enforces non-PROD servers cannot be active
- `INSERT INTO dbo.GlobalConfig` -- `bdl_promote_cooldown_seconds` (120, INT, Tools/Operations)

**Object_Metadata entries completed this session (April 6):**
- `staging_table` column description on `BDL_ImportLog`
- `is_active` column description updated on `ServerRegistry` (metadata_id 662) -- now references orchestrator enrollment
- `environment` column description updated on `ServerRegistry` (metadata_id 658) -- references CHECK constraint
- Environment status_values renamed: QA→TEST, UAT→STAGE with updated descriptions
- `is_active` status_values added: 1 = enrolled (PROD only), 0 = registered but not enrolled
- Design note added: "Environment-Based Activation Constraint"

**Object_Registry entries completed prior session (April 4):**
- `BDL_ImportTemplate` table -- registered with Object_Metadata baselines, column descriptions, data flow, design notes, and relationship notes

**Object_Metadata entries completed prior session (April 4):**
- `parent_log_id` column description on `BDL_ImportLog`
- `AR Log Companion Pattern` design note on `BDL_ImportLog`

**System_Metadata version bumps needed (end of session -- DEFERRED from April 6):**
- **Module: Tools -> Component: Tools.Operations** -- `staging_table` column on BDL_ImportLog, promote cooldown GlobalConfig entry
- **Module: ControlCenter -> Component: ControlCenter.BDLImport** -- Styled modals (all alert/confirm replaced), XML preview auto-load with copy button, promote to production flow, PROD advisory modal, environment unlock, back button hide on success, row count shows non-skipped
- **Module: ControlCenter -> Component: ControlCenter.Shared** -- `showAlert()` and `showConfirm()` added to engine-events.js, `xf-modal-*` CSS added to engine-events.css, `_escapeModalText()` helper, `xfModalFadeIn` animation
- **Module: ServerOps -> Component: ServerOps.ServerHealth** -- ServerRegistry CHECK constraint (environment/is_active)

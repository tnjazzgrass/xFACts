# Tools

*Operational tools and vendor specification catalogs for Debt Manager*

The Tools module houses the operational side of xFACts — the things that actually *do* things to Debt Manager rather than just watch it. BDL imports, consumer lookups, scheduled job triggers, and the vendor specification catalogs that drive them all live here. If the monitoring modules are the eyes and ears, Tools is the hands.






What Lives in Tools

**BDL Import** — A guided wizard for importing bulk data into Debt Manager. Upload a vendor file, map columns to BDL fields, validate the data against DM’s reference tables, and submit — all from the Control Center. Replaces the manual copy-paste workflow from the legacy Access toolkit with proper validation, audit logging, and RBAC-controlled access per entity type and field.

**Client Portal** — Consumer and account lookup with detailed views across five consumer tabs and three account tabs. Search by consumer ID, account ID, SSN, name, or phone number. Read-only access to DM’s operational data for quick reference without opening the DM application directly.

**Vendor Specification Catalogs** — The BDL Format Registry and Element Registry define every BDL entity type and its fields. These catalogs drive the Import wizard’s column mapping, validation rules, and XML construction. Managed through the BDL Content Management admin modal on the Applications & Integration page.






User Guides

Step-by-step walkthroughs for Tools module features. Each guide covers what you’ll see on screen and how to use it.



BDL Import Guide
Walk through the 5-step import wizard: environment selection, file upload, entity selection, column mapping and validation, and execution with Promote to Production.
Available









Platform

Platform-wide views that cut across the modules rather than belonging to any one of them.



Backlog
Open work items across the platform, grouped by component and priority-ordered within each group. Filter by component, priority, or type, search the summary, label, and description text, and expand any item for its full detail.
Available

---

# BDL Import — User Guide

*A step-by-step walkthrough for importing bulk data into Debt Manager*

The BDL Import wizard lets you upload a vendor data file, map its columns to Debt Manager fields, validate the data, and submit it as a Bulk Data Load — all from your browser. No more copy-pasting into Access tables. No more hardcoded XML. Just point, click, and let the system do the heavy lifting.



This guide walks through every screen of the 5-step wizard. Whether you’re importing phone numbers, tagging consumers, or updating account data, the workflow is the same. If you’ve used the old Access toolkit, think of this as that — minus the 90 MB file size and the existential dread of opening a shared database.
**Access:** The BDL Import page is available to the Applications & Integration team (full access to all entity types) and the Business Intelligence team (access to department-specific entity types configured by an administrator). Page access is controlled via RBAC; entity and field access are controlled per department.










## 1. Select Your Environment


The first thing you’ll see is three cards — one for each Debt Manager environment. Click the one you want to target. This determines which server receives the file and processes the import.



Once you select an environment, a color-coded badge appears in the stepper bar and stays visible throughout the wizard. It’s a constant reminder of where your data is going — because accidentally importing 10,000 phone records into production when you meant to test is the kind of Monday nobody wants.


TEST&ensp;
STAGE&ensp;
PROD
← Environment badge colors


Selecting **PROD** shows an advisory modal confirming you intend to target production directly. You can still proceed — it’s a heads-up, not a block. The environment card border and name color switch to red for production as an additional visual cue.

**Best practice:** Always validate new file formats or entity type configurations on TEST first. Once you’re confident the import is correct, you can re-run it on PROD — or use the Promote to Production feature from Step 5.








## 2. Upload Your Data File


Drag a file into the upload zone, or click **Browse Files** to select one. Accepted formats are CSV, TXT (tab-delimited), XLS, and XLSX. The file is parsed entirely in your browser — nothing is uploaded to a server at this step.



Once a file is loaded, a preview grid appears showing the first several rows. The file info bar above the grid shows the filename, row count (excluding the header row), and column count.



**Excel dates:** If your file contains date columns, Excel-formatted date serial numbers are automatically converted to `YYYY-MM-DD` format. You don’t need to pre-format them.

The file stays in browser memory for the rest of the wizard. If you need to change the file, click **Back** to return here and upload a different one. The practical size limit is approximately 250,000 rows per import. For Excel files, the first sheet is used.








## 3. Select Entity Types


Entity types are the categories of data you can import — phone numbers, consumer tags, account tags, addresses, and so on. Each entity type maps to a specific BDL transaction type in Debt Manager.

Cards are grouped into three sections: **Consumer** (entities keyed by consumer number), **Account** (entities keyed by account number), and **Other**. Click a card to select it; click again to deselect. You can select multiple entity types if your file contains data for more than one BDL operation.



The i icon on each card opens a **field info modal** showing all available fields for that entity type. This is a quick way to check what data the entity expects before selecting it. The modal shows display names, descriptions, and import guidance tips (in amber) when populated. Fields that support nullification show a purple &empty; icon.

Some entity types (like Consumer Tag and Account Tag) use an assignment card interface instead of the drag-and-drop column mapping. When you reach Step 4 for one of these entities, you’ll see the assignment cards automatically. See the Fixed-Value Entities section below for details.

**Multi-entity workflow:** When you select multiple entities, Step 4 walks through each one individually — map then validate for Entity 1, then map then validate for Entity 2, and so on. Progress dots at the top of Step 4 show where you are in the sequence. All entity states are preserved if you navigate back.








## 4. Map & Validate


This is where the real work happens. For each selected entity type, you’ll map columns from your file to BDL fields, then validate the data. The wizard handles one entity at a time — when you complete mapping and validation for the first entity, it automatically transitions to the next.

When you’ve selected multiple entities, progress dots at the top show where you are:




### Identifier Column

**First things first: select your identifier column.** Before any mapping is enabled, you must tell the system which column in your file contains the consumer or account number. This is the column DM uses to locate the right record.

The identifier section adapts based on the entity type. Consumer-level entities (Phone, Consumer Tag, etc.) ask for the **DM Consumer number** and map to `cnsmr_idntfr_agncy_id`. Account-level entities (Account Tag, etc.) ask for the **DM Account number** and map to `cnsmr_accnt_idntfr_agncy_id`.



The identifier section has a red border when nothing is selected and a green border once confirmed. The rest of the mapping interface stays dimmed and disabled until this is set.



### File-Mapped Entities

For most entity types, you’ll see a two-panel layout: **Source Columns** (your file) on the left, and **BDL Fields** (target fields) on the right. Drag source chips from the left and drop them onto target chips on the right. Or click a source chip, then click the target chip you want to map it to. Mapped pairs appear in a **Mapped** section below.



**Visual indicators on target field chips:**
**Amber left border + “required” label:** This field is required for a successful import. If it’s not mapped and has no value, the import will either fail or silently do nothing. Don’t ignore these.
&empty; **Null badge (purple):** This field supports nullification. Clicking it marks that field for nullification across every row. See Nullifying Field Values below.
Fields may also show an amber **import guidance** tip — these are operational notes about how the field behaves (e.g., “Required numeric value — enter 0 if not in source data”).


Per-Field Mode Override
Some fields on file-mapped entities are eligible for a **per-field mode override**. These fields show a compact 3-way toggle directly on their target chip: **File**, **Blanket**, and **Cond** (Conditional).



**File (default):** The field stays in the target panel for normal drag-and-drop mapping from a source column. This is standard behavior — the value comes from each row of your file.

**Blanket:** One fixed value is applied to all rows. When you select Blanket, the field moves from the target panel into a **Field Assignments** section below the mapping panels. You enter a single value there (with typeahead for lookup fields), and it applies uniformly to every row in the import.

**Cond (Conditional):** The field value varies per row based on a trigger column. You select a column from your file as the “trigger,” the system scans the file for unique values in that column, and you map each unique trigger value to a field value using typeahead. Rows whose trigger value isn’t mapped are skipped.



**Use case:** You’re importing a CONSUMER entity update. Most fields come from the file, but you want to reassign all records to a specific workgroup. Switch the workgroup field to Blanket, type the workgroup name, and the file-mapped fields handle the rest.


Fixed-Value Entities (Tags)
Tag entities (like CONSUMER_TAG and ACCOUNT_TAG) use an **assignment card** interface. Instead of mapping file columns to every field, you define one or more assignments — each specifying what tag value to apply and how to determine it.

Each assignment card has a mode toggle (when the entity supports it):



**Blanket mode:** Every row in your file gets the same tag value. You enter the tag name (with typeahead against DM’s tag table) and any shared fields. Simple and common — “tag all these consumers with TA_PRIORITY.”

**From File mode:** The tag value is read from a column in your file rather than entered manually. You select which file column contains the tag short names. Rows where the column is empty are skipped. Shared fields (like assignment date) are entered once and applied to all rows.

**Conditional mode:** The tag value varies based on a trigger column. You select a file column as the trigger, the system scans for unique values, and you map each trigger value to a tag using typeahead. This is useful when different rows should get different tags based on some criteria in the file.



**Multiple assignments:** Click **+ Add Another** to stack multiple assignments. Each card is independent — you can mix modes (one blanket, one conditional, etc.). Each assignment generates its own set of rows in the staging table, so the same consumer can receive multiple tags from a single import.

**Tag entity filtering:** When importing Consumer Tags, the typeahead and validation lookups only show consumer-level tags. Likewise, Account Tags only show account-level tags. This prevents accidentally selecting a tag meant for the wrong entity level.


Nullifying Field Values
Sometimes you need to **clear** a field value in DM rather than update it. BDL Import supports this through the `<nullify_fields>` XML block. There are two mechanisms:

**Blanket nullification:** On target field chips, eligible fields show a purple &empty; badge. Clicking it marks that field for nullification across *every row*. The field moves to the Mapped section with a purple “&empty; Nullify → Field Name” label. Use this when you want to deliberately wipe a field value for an entire batch.

**Record-level nullification:** When a column is mapped but a row has an **empty value**, the system automatically nullifies that field for that row. The logic: if you mapped the column, the file controls that field. Empty means “clear it,” not “leave it alone.” Unmapped fields are simply omitted from the XML. This mirrors the legacy Access toolkit behavior.

Primary identifiers, required fields, fields flagged as non-nullifiable, and conditional-eligible fields (which use the mode toggle instead) are excluded from nullification. The &empty; badge only appears on eligible fields.



### Validation

After mapping, click the **Validate [Entity Name]** button to validate. The system stages your data on the server, fetches reference values from DM, and checks every row. Issues appear as accordion cards — one category at a time, most critical first.



**Required Empty** (actionable) — A required field has no value. **Fill** applies a value to all empty rows for that field, or **Skip** removes the affected rows. The amber tip is the import guidance.

**Invalid Lookup** (actionable) — Values don’t match DM reference tables. **Replace** with a valid value (per unique invalid value) or **Skip** those rows. For fields with a skip button that do not allow nullification, the Skip option is hidden.

**Max Length** and **Data Type** (informational) — Warnings about truncation or type mismatches. These won’t block the import but DM may reject individual records.

**Cascading validation:** After each fill or skip action, the system re-validates automatically. Skipping rows for one field removes them from subsequent checks, so counts may change as you work through issues.

Once all actionable issues are resolved (or there are none), validation passes and the entity is marked complete. A summary shows the mapped fields, nullified fields (if any), and row counts. If more entities remain, the wizard transitions to the next one after a brief pause.








## 5. Review & Execute


The final step shows a summary of everything you’re about to import, with one tab per entity type. Each tab shows a 4-item grid (Environment, Entity Type, Rows, Staging Table), plus summary cards for mapped fields and nullified fields.



**XML Preview:** Click the **Preview XML** button to see the exact XML that will be sent to DM. Useful for verifying output before submitting, especially with a new entity type. The preview can be copied to clipboard.

**Jira Ticket (optional):** Enter a ticket number (e.g., SD-1234) before executing. The system generates a single consolidated AR log covering all entities in the batch, creating an audit trail in DM on every imported consumer account.

**Executing:** Click **Submit All** to submit. Each entity type is processed independently — build XML, write file, register via DM API, trigger import. If one entity fails, the others are unaffected. Tab labels update with checkmarks or X indicators as each completes.



The DM import is attributed to **your** AD username, not the API service account.



### Row Count Alignment

When importing multiple entity types and the row counts differ (which happens when fixed-value entities expand differently from file-mapped entities), a **mismatch banner** appears at the top of Step 5. This is important because tag entities are typically “derivative” — they should only apply to the same records as the primary file-mapped entity.

Click **Align Row Counts** to open a modal. For each fixed-value entity, you can select which file-mapped entity to align to. Alignment joins the staging tables on the shared identifier column and marks rows as skipped in the target that are skipped in the source. Each entity has an **Undo** button to reset alignment if needed.

**Design principle:** File-mapped entities are independent (“load this data”). Fixed-value entities are derivative (“apply this to those records”). Alignment keeps them in sync.



### Promote to Production

After a successful non-PROD import, a **Promote to Production** card appears below the results. It has a cooldown timer that counts down before enabling — giving you time to verify results in the lower environment first.



Clicking it (after cooldown) opens a confirmation modal showing the source environment, entity list with row counts, and a production warning. Confirming swaps the environment to PROD, resets execution state, and re-renders Step 5 so you can review the summary, preview XML, and submit.

**Promote is optional.** You can always go back to Step 1, select PROD, and run the wizard from scratch. Promote just saves you the round trip when the data has already been validated.








## Mapping Templates


If you frequently import files with the same column layout, templates save you from re-mapping every time. Templates store the column-to-field mapping for a specific entity type and can be applied to new imports with a single click.

The **template panel** lives in the right column below the step guide. When you’re on the mapping screen (Step 4), it shows all saved templates for the current entity type.

**Loading a template:** Click a template name to preview the stored mappings in a slideout panel. If the template’s source columns match your file’s column headers (case-insensitive), click **Apply** and the mapping is done instantly. If some columns don’t match, the template applies what it can and you map the rest manually. A match indicator shows how many fields matched.

**Saving a template:** After you’ve completed a mapping, click **Save Current Mapping as Template** at the bottom of the template panel. Give it a descriptive name (e.g., “Acme Phone Export”) and an optional description. The template is tied to the entity type and available to all users.

**Managing templates:** Template creators and administrators can edit or deactivate templates from the slideout preview. Deactivated templates are hidden from the list but not deleted.








## Tips & Troubleshooting



### The Right Column

The right side of the page has two sections. The **step guide panel** at the top updates automatically as you move through steps with context-specific tips. The **template panel** below it is relevant during Step 4 (mapping).


### Going Back

The **Back** button preserves state. If you’re on entity 2 of 3 in the mapping step, Back takes you to entity 1 (not all the way back to Step 3). From entity 1, Back takes you to Step 3. Your mappings, assignments, and validation results are preserved — nothing is lost.


### Clicking the Stepper

You can click completed steps in the stepper bar to jump back directly. You cannot click forward to steps you haven’t reached yet. Completed steps show a green checkmark.


### Re-Staging Detection

If you go back and change your mappings, assignments, or field mode overrides after staging, the system detects the change and automatically re-stages the data when you validate again. The old staging table is dropped and a fresh one is created.


### Staging Table Cleanup

Staging tables are automatically cleaned up after 48 hours. If expired tables are detected when you load the page, a cleanup banner appears at the top offering to remove them.


### What Happens After You Execute

The import file lands on the DM file share, gets registered via the REST API, and the import is triggered. From there, DM’s internal processing takes over. You can monitor import progress on the **Batch Monitoring** page under the BDL section.


### Error Recovery

If an import fails, the error is displayed in the results pane. In most cases, DM requires a **new file with a new name** for retry — go back to Step 1 and start fresh; the system generates a unique batch ID for each submission.
However, if the file was successfully registered with DM but the import trigger failed (typically a timing issue where the file wasn’t ready yet), a RETRY badge will appear next to the FAILED status in the Import History panel. Clicking it re-fires the import trigger against the existing registered file without needing to start over. The retry is available to the user who ran the original import and to page admins.


### File Size Limits

The practical limit is approximately 250,000 rows per import. For larger datasets, split the file and run them sequentially.


### Access Control

Three layers control what you can do: **RBAC page access** (who can see the page), **entity access** (which BDL entity types your department can use), and **field access** (which fields within each entity are available). If you don’t see an entity type you expect, contact the Applications team. Admin-tier users bypass all access restrictions.

---

## Reference

### AccessConfig

Controls which tools and entity types are available for use, and which departments can access each one. Admin tier users on the Tools page bypass department filtering and see all enabled items. Non-admin users see only items explicitly granted to their department.

**Data Flow:** Rows are manually inserted to grant department-level access to specific tools and entity types. The BDL Import entity picker queries this table filtered by the logged-in user's department scope to determine which entity types to display. Admin tier users skip this check entirely and see all enabled entities from the catalog. Future tool types (CDL, Payment, API) use the same table with different tool_type values.

**Admin Tier Bypass:** [sort:1] Users with admin tier on the Tools page see all enabled entities regardless of AccessConfig rows. This table only filters non-admin users. The Applications team receives admin tier on the BDL Import page, so no AccessConfig rows are needed for them. Only departments with restricted access (e.g., Business Intelligence) require rows.

**Column NULL Semantics:** [sort:2] A NULL item_key means access to the tool type itself without sub-item granularity — used for tools like Drools Refresh that have no entity picker. A NULL department_scope would mean unrestricted access to all departments, but this is not the expected pattern — admin tier handles unrestricted access. Rows should always have a department_scope populated.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| config_id (IDENTITY) | int | No | IDENTITY | Identity primary key. |
| tool_type | varchar(30) | No | — | Identifies the tool or pipeline this access grant applies to. Values include BDL, CDL, PAYMENT, NEWBUSINESS, API, and other tool identifiers as they are added. No check constraint — values are open to accommodate future tools. |
| item_key | varchar(60) | Yes | — | Specific item within the tool type that access is being granted to. For BDL and CDL, this is the entity_type from the corresponding catalog table (e.g., PHONE, CONSUMER_TAG). NULL for tools that do not have sub-item granularity. |
| department_scope | varchar(50) | Yes | — | Department key this access grant applies to. Matches RBAC_DepartmentRegistry.department_key. Rows should always have a department_scope populated — unrestricted access is handled by admin tier bypass, not by NULL scope rows. |
| is_active | bit | No | 1 | Whether this access grant is active. 0 = disabled, 1 = enabled (default). |
| created_dttm | datetime | No | getdate() | When the access grant was created. |
| created_by | varchar(100) | No | suser_sname() | Who created the access grant. |
| modified_dttm | datetime | Yes | — | When the access grant was last modified. |
| modified_by | varchar(100) | Yes | — | Who last modified the access grant. |

  - **PK_AccessConfig** (CLUSTERED): config_id -- PRIMARY KEY
  - **UQ_AccessConfig_tool_item_dept** (NONCLUSTERED): tool_type, item_key, department_scope

**Available BDL entities for a department** [sort:1] -- Returns the BDL entity types accessible to a specific department. Join to Catalog_BDLFormatRegistry for display names and field details.

```sql
SELECT ac.item_key AS entity_type, f.type_name, f.folder, f.element_count
FROM Tools.AccessConfig ac
INNER JOIN Tools.Catalog_BDLFormatRegistry f
    ON f.entity_type = ac.item_key
    AND f.spec_version = '11.1.0.1.6'
WHERE ac.tool_type = 'BDL'
    AND ac.department_scope = 'business-intelligence'
    AND ac.is_active = 1
ORDER BY f.folder, f.entity_type;
```

**All access grants by tool type** [sort:2] -- Shows the complete access matrix across all departments and tool types.

```sql
SELECT tool_type, item_key, department_scope, is_active
FROM Tools.AccessConfig
ORDER BY tool_type, item_key, department_scope;
```

  - **dbo.RBAC_DepartmentRegistry**: [sort:1] Logical relationship. department_scope matches RBAC_DepartmentRegistry.department_key. No physical foreign key — validated at the application layer, consistent with the RBAC_RoleMapping pattern.
  - **Tools.Catalog_BDLFormatRegistry**: [sort:2] Logical relationship. For BDL tool_type rows, item_key corresponds to Catalog_BDLFormatRegistry.entity_type. No physical foreign key since AccessConfig spans multiple tool types and catalogs.
  - **AccessFieldConfig**: [sort:3] Parent table. AccessFieldConfig rows provide a field-level whitelist for department-scoped entity grants. When AccessFieldConfig rows exist for a config_id, only those fields are accessible to the department. No AccessFieldConfig rows means zero field access (strict whitelist). Admin tier users bypass both tables entirely.


### AccessFieldConfig

Whitelist of BDL element fields accessible to a department for a specific entity type. Child of AccessConfig — each row grants access to one field within the parent entity grant. Admin tier users bypass this table entirely. When an AccessConfig row exists but has no AccessFieldConfig children, the department has zero field access to that entity (strict whitelist). Fields not in this table are invisible to the department in the column mapping UI.

**Data Flow:** Rows are manually inserted when granting a department access to specific fields within a BDL entity type. The BDL Import entity-fields API endpoint queries this table for non-admin users, returning only fields that have an active whitelist row for the user's department. Admin tier users skip this check and see all visible fields from the catalog. The config_id foreign key links to AccessConfig, which provides the entity type and department scope context.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| field_config_id (IDENTITY) | int | No | IDENTITY | Identity primary key. |
| config_id | int | No | — | FK to Tools.AccessConfig. Identifies the parent entity-level access grant this field whitelist belongs to. |
| element_name | varchar(80) | No | — | BDL element name being granted. Matches Catalog_BDLElementRegistry.element_name. |
| is_active | bit | No | 1 | Whether this field grant is active. 0 = disabled, 1 = enabled (default). |
| created_dttm | datetime | No | getdate() | When the field grant was created. |
| created_by | varchar(100) | No | suser_sname() | Who created the field grant. |
| modified_dttm | datetime | Yes | — | When the field grant was last modified. |
| modified_by | varchar(100) | Yes | — | Who last modified the field grant. |

  - **PK_AccessFieldConfig** (CLUSTERED): field_config_id -- PRIMARY KEY
  - **UQ_AccessFieldConfig_config_element** (NONCLUSTERED): config_id, element_name

**Foreign Keys:**

  - **FK_AccessFieldConfig_AccessConfig**: config_id -> Tools.AccessConfig.config_id

  - **AccessConfig**: [sort:1] Child table. config_id references AccessConfig.config_id. Each AccessFieldConfig row grants access to one element within the entity and department defined by the parent AccessConfig row. No child rows means zero field access (strict whitelist).
  - **Catalog_BDLElementRegistry**: [sort:2] element_name references element names from Catalog_BDLElementRegistry. No formal FK — the element catalog may be reloaded independently. Validation is enforced at the application layer during field access queries.


### BDL_ImportLog

Audit trail for BDL import executions. One row per import capturing the full lifecycle from file upload and validation through XML construction, DM file registration, submission, and DM-side terminal state reconciliation. Tracks who executed each import, against which environment, for which entity type, and what the final DM outcome was.

**Data Flow:** A row is inserted when a user initiates a BDL import from the Control Center, initially with VALIDATING status. The status column is updated as the import progresses through the lifecycle: VALIDATING (data checks running), BUILDING (XML file being constructed), REGISTERED (file registered with DM via POST /fileregistry), SUBMITTED (import triggered via POST /fileregistry/{id}/bdlimport), COMPLETED (reconciliation confirmed DM terminal success), or FAILED (error at any stage or DM reported terminal failure). The column_mapping JSON is captured at validation time. The file_registry_id is populated after successful DM registration. After submission, the reconciliation helper in xFACts-Helpers.psm1 — invoked on demand by the /api/bdl-import/history endpoint — queries the target environment's dbo.File_Registry using the stored file_registry_id, writes back terminal status and record counts from the file_rgstry_cstm_dtl Dm_* metrics, and sets is_complete = 1 when DM-side processing reaches a terminal state. Rows are append-only — status updates modify the existing row but no rows are ever deleted.

**Column Mapping Audit Trail:** [sort:1] The column_mapping column stores a JSON representation of the field mapping used for the import — which source file columns were mapped to which BDL element names. This provides a complete audit trail of what was actually imported, regardless of whether a template was used. When a template is selected, the mapping is locked (read-only in the UI) and the template_id is also recorded.

**Error Recovery Pattern:** [sort:2] Failed imports require a new file with a new filename to be registered with DM — re-importing a previously registered file is not supported. A retry creates a new BDL_ImportLog row rather than updating the failed row. The failed row preserves the error context for diagnostics.

**DM Import Status Confirmation:** [sort:3] The SUBMITTED to COMPLETED/FAILED transition is driven by on-demand reconciliation, not a scheduled collector. The /api/bdl-import/history endpoint invokes Invoke-BDLImportLogReconcile in xFACts-Helpers.psm1, which groups non-terminal rows (is_complete = 0) by environment, resolves the target db_instance from Tools.EnvironmentConfig, and issues one batched query per environment against dbo.File_Registry using the stored file_registry_id. Terminal File_Registry status codes (5 = PROCESSED, 6 = FAILED, 7 = CANCELED, 8 = PARTIALLY_PROCESSED) drive the write-back — status is advanced to COMPLETED or FAILED, file_registry_status captures DM's detailed vocabulary, and record counts are sourced from file_rgstry_cstm_dtl Dm_* metrics. Rows that cannot be located in File_Registry after repeated lookups are flagged ORPHANED, typical after environment refreshes. is_complete = 1 stops further reconciliation attempts on terminal or orphaned rows. Frontend polling (GlobalConfig-driven interval) drives repeated reconciliation while a user has the history panel open.

**AR Log Companion Pattern:** [sort:4] When a Jira ticket is provided during import execution, the system generates a single consolidated CONSUMER_ACCOUNT_AR_LOG BDL file after all primary entity imports complete. This file creates a clerical comment (CC/CC action/result codes) on each imported record linking it back to the ticket, with the AR message referencing all entity types in the batch (e.g., "JIRA-123: PHONE, CONSUMER_TAG update via BDL Import"). This replaces the earlier per-entity AR log pattern with a single companion file per batch execution. The AR log is built from the first successful entity's staging table (identifiers are consistent across aligned entities). parent_log_ids stores a comma-separated list of all primary import log_id values the AR log covers. On the DM side, the AR log file has its own file_registry_id and processes through the BDL pipeline independently. AR log failure does not roll back primary imports.

**DM Reconciliation Pattern:** [sort:5] Reconciliation is driven on demand by the /api/bdl-import/history endpoint — there is no scheduled collector dedicated to this table. When the history endpoint is called, Invoke-BDLImportLogReconcile groups rows where is_complete = 0 by environment, resolves the target db_instance from Tools.EnvironmentConfig, and issues a single batched query per environment against dbo.File_Registry. This spans TEST, STAGE, and PROD — a deliberate choice to keep manual import tracking cross-environment without creating a dependency on the BatchOps BDL collector (which runs PROD-only). Frontend polling drives repeated reconciliation while a user has the page open; the GlobalConfig setting bdl_history_poll_seconds controls the poll interval. Terminal rows (is_complete = 1) are filtered out by the reconcile query itself, so load stays proportional to actively in-flight imports. Orphan handling covers the case where a lower-environment refresh removes DM-side File_Registry rows — after repeated lookup failures, the row is flagged ORPHANED and is_complete is set to 1 to stop further attempts.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| log_id (IDENTITY) | int | No | IDENTITY | Identity primary key. |
| server_config_id | int | No | — | FK to Tools.ServerConfig. Identifies the environment and server configuration used for this import. |
| environment | varchar(20) | No | — | Denormalized environment from ServerConfig (PROD, STAGE, TEST). Avoids joins for common queries and history views. |
| entity_type | varchar(60) | No | — | BDL entity type imported (e.g., PHONE, CONSUMER_TAG). Matches Catalog_BDLFormatRegistry.entity_type. |
| source_filename | varchar(260) | No | — | Original filename of the file uploaded by the user (CSV or Excel). |
| xml_filename | varchar(260) | Yes | — | Name of the BDL XML file written to the dmfs import folder. NULL until the BUILDING stage completes. Used for DM file registration. |
| staging_table | varchar(200) | Yes | — | Name of the Staging schema table used for this import. Correlates test-to-production imports — when the same staging table name appears on multiple rows across different environments, it indicates the user tested before promoting to production. A PROD row with a staging_table that has no corresponding TEST/STAGE row indicates a direct-to-production import. |
| row_count | int | Yes | — | Number of data rows in the uploaded file. NULL until file parsing completes. Excludes header rows. |
| validation_errors | int | No | 0 | Count of rows that failed validation. 0 indicates a clean validation pass. Populated during the VALIDATING stage. |
| column_mapping | varchar(MAX) | Yes | — | JSON representation of the field mapping used for this import. Captures which source file columns were mapped to which BDL element names. Provides a complete audit trail independent of whether a template was used. |
| value_changes | varchar(MAX) | Yes | — | JSON array of value replacements applied by the user during the validation step. Each entry captures the field name, original value, replacement value, affected row count, who made the change, and when. NULL when no replacements were applied. Provides full audit trail from source file content to final import data. |
| template_id | int | Yes | — | FK to future template table. Identifies the saved column mapping template used for this import. NULL indicates an ad-hoc mapping was configured manually. |
| parent_log_ids | varchar(200) | Yes | — | Comma-separated list of primary import log_id values that this companion AR log row covers. NULL for primary imports. Populated when the execute-ar-log endpoint generates a consolidated AR log file linking back to one or more primary import rows. Replaces the former parent_log_id single FK column to support consolidated AR logs spanning multiple entity types in a single batch execution. |
| status | varchar(20) | No | 'VALIDATING' | Current lifecycle status of the import. Progresses through VALIDATING, BUILDING, REGISTERED, SUBMITTED, COMPLETED, or FAILED. See status values for details. |
| error_message | varchar(2000) | Yes | — | Error details captured on failure. NULL when status is not FAILED. May contain DM API error responses, validation summary, file system errors, or DM-side processing errors from File_Registry.file_err_msg_txt populated by reconciliation when DM reports a terminal failure. |
| executed_by | varchar(100) | No | — | AD username of the Control Center user who initiated the import. Captured from the authenticated session at import start. |
| started_dttm | datetime | No | getdate() | When the import process was initiated by the user. |
| completed_dttm | datetime | Yes | — | When the import reached a terminal status (COMPLETED or FAILED). Sourced from File_Registry.upsrt_dttm when reconciliation advances SUBMITTED to a terminal state. Set to GETDATE() on xFACts-side FAILED transitions. NULL while the import is in progress. |
| file_registry_id | int | Yes | — | File registry ID returned by the DM REST API after successful file registration (POST /fileregistry). NULL until the REGISTERED stage. Used as the path parameter for the import trigger call. |
| file_registry_status_code | int | Yes | — | DM File_Registry.file_stts_cd at the time of reconciliation write-back. Terminal values: 5 = PROCESSED, 6 = FAILED, 7 = CANCELED, 8 = PARTIALLY_PROCESSED. NULL until reconciliation captures a terminal state. Stored alongside file_registry_status (the string form) for operational convenience. |
| file_registry_status | varchar(30) | Yes | — | DM terminal status string captured by reconciliation. Values: PROCESSED, PARTIALLY_PROCESSED, FAILED, CANCELED, ORPHANED. ORPHANED is not a DM code — reconciliation sets it when File_Registry returns no row after repeated attempts, typically after a lower-environment refresh removed the DM-side record. NULL until reconciliation captures a terminal state. |
| total_record_count | int | Yes | — | Total record count reported by DM (file_rgstry_dtl.file_rgstry_dtl_rec_ttl_cnt). Populated by reconciliation after DM processes the file. Distinct from row_count, which captures the uploaded file's data row count at validation time. |
| staging_success_count | int | Yes | — | Records successfully staged in DM during the first phase of BDL processing. Populated by reconciliation from the Dm_staging_success_count custom detail on file_rgstry_cstm_dtl. |
| staging_failed_count | int | Yes | — | Records that failed staging validation in DM. Populated by reconciliation from the Dm_staging_failed_count custom detail on file_rgstry_cstm_dtl. Non-zero values indicate data quality issues that prevented staging even though the file itself was syntactically valid. |
| import_processed_count | int | Yes | — | Total records DM attempted to import (equal to import_success_count + import_failed_count). Populated by reconciliation from the Dm_import_processed_count custom detail on file_rgstry_cstm_dtl. |
| import_success_count | int | Yes | — | Records successfully imported by DM into the target entity tables. Populated by reconciliation from the Dm_import_success_count custom detail on file_rgstry_cstm_dtl. Primary indicator of import success alongside file_registry_status. |
| import_failed_count | int | Yes | — | Records that failed during the DM import phase (post-staging). Populated by reconciliation from the Dm_import_failed_count custom detail on file_rgstry_cstm_dtl. Non-zero values combined with PARTIALLY_PROCESSED status indicate rows that staged cleanly but failed during commit to the target tables. |
| is_complete | bit | No | 0 | Completion flag driving reconciliation eligibility. 0 = active (reconciliation will attempt DM lookup on next history page load). 1 = terminal (reconciliation skips this row entirely). Set to 1 by reconciliation when DM reports any terminal file_stts_cd, when a row is flagged ORPHANED, or at xFACts-side FAILED transitions. Backed by filtered index IX_BDL_ImportLog_reconcile for efficient reconcile queries. |
| last_polled_dttm | datetime | Yes | — | Timestamp of the most recent reconciliation attempt against DM File_Registry for this row. Updated every time the row is queried regardless of whether a terminal state was captured. Used by the history UI to display "last checked" timing and by the reconciliation helper to detect rows that have gone unresolved for extended periods. |
| created_dttm | datetime | No | getdate() | When the log row was created. |
| created_by | varchar(100) | No | suser_sname() | Who created the log row. |

  - **PK_BDL_ImportLog** (CLUSTERED): log_id -- PRIMARY KEY
  - **IX_BDL_ImportLog_entity** (NONCLUSTERED): entity_type, environment [includes: status, row_count, executed_by, started_dttm]
  - **IX_BDL_ImportLog_executed_by** (NONCLUSTERED): executed_by, started_dttm [includes: entity_type, environment, status]
  - **IX_BDL_ImportLog_reconcile** (NONCLUSTERED): is_complete [includes: file_registry_id, environment, status, last_polled_dttm, started_dttm]
  - **IX_BDL_ImportLog_status** (NONCLUSTERED): status, started_dttm [includes: entity_type, environment, executed_by]

**Check Constraints:**

  - **CK_BDL_ImportLog_status**: `([status]='FAILED' OR [status]='COMPLETED' OR [status]='SUBMITTED' OR [status]='REGISTERED' OR [status]='BUILDING' OR [status]='VALIDATING')`

**Foreign Keys:**

  - **FK_BDL_ImportLog_ServerConfig**: server_config_id -> Tools.EnvironmentConfig.config_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| file_registry_status | PROCESSED | DM File_Registry.file_stts_cd = 5. All records processed successfully. Paired with status = COMPLETED. Record counts: import_success_count should match total_record_count with import_failed_count = 0. | 1 |
| file_registry_status | PARTIALLY_PROCESSED | DM File_Registry.file_stts_cd = 8. Some records processed, others failed during import. Paired with status = COMPLETED. import_failed_count is non-zero; check import_success_count and import_failed_count for the split. | 2 |
| file_registry_status | FAILED | DM File_Registry.file_stts_cd = 6. Processing failed before completion. Paired with status = FAILED. error_message populated from File_Registry.file_err_msg_txt. | 3 |
| file_registry_status | CANCELED | DM File_Registry.file_stts_cd = 7. Processing was canceled. Paired with status = FAILED. Rare in practice — canceled imports typically result from manual DM-side intervention. | 4 |
| file_registry_status | ORPHANED | Not a DM code. Set by reconciliation when dbo.File_Registry returns no row for the stored file_registry_id across repeated lookup attempts. Typically occurs after a lower-environment refresh removed DM-side records, or when file_registry_id was never populated due to registration failure. is_complete is set to 1 to stop further reconciliation attempts. | 5 |
| status | VALIDATING | Import initiated. Uploaded file is being parsed and data validation checks are running against the column mapping. | 1 |
| status | BUILDING | Validation passed. The BDL XML file is being constructed from the mapped data. | 2 |
| status | REGISTERED | XML file written to dmfs and registered with DM via POST /fileregistry. file_registry_id is now populated. | 3 |
| status | SUBMITTED | BDL import triggered via POST /fileregistry/{id}/bdlimport. Transitional state — file handed off to DM, awaiting reconciliation to a terminal state. Reconciliation advances SUBMITTED to COMPLETED or FAILED based on File_Registry.file_stts_cd. | 4 |
| status | COMPLETED | DM reported terminal success via File_Registry.file_stts_cd (5 = PROCESSED or 8 = PARTIALLY_PROCESSED). Set by reconciliation along with file_registry_status, record counts, and completed_dttm. | 5 |
| status | FAILED | Import failed at any stage. xFACts-side validation, registration, or submission failures set this directly. Reconciliation also sets this when DM reports File_Registry.file_stts_cd 6 = FAILED or 7 = CANCELED — file_registry_status captures which. error_message contains details. A retry requires a new import with a new filename. | 6 |

**Recent import history** [sort:1] -- Shows the most recent BDL imports across all environments with key details.

```sql
SELECT TOP 50 log_id, environment, entity_type, source_filename,
    row_count, validation_errors, status, error_message,
    executed_by, started_dttm, completed_dttm
FROM Tools.BDL_ImportLog
ORDER BY log_id DESC;
```

**Failed imports requiring attention** [sort:2] -- Shows failed imports that may need retry or investigation.

```sql
SELECT log_id, environment, entity_type, source_filename,
    row_count, status, error_message,
    executed_by, started_dttm
FROM Tools.BDL_ImportLog
WHERE status = 'FAILED'
ORDER BY started_dttm DESC;
```

**Import activity by user** [sort:3] -- Shows import counts and outcomes per user for auditing.

```sql
SELECT executed_by, environment, entity_type,
    COUNT(*) AS total_imports,
    SUM(CASE WHEN status = 'COMPLETED' THEN 1 ELSE 0 END) AS completed,
    SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) AS failed
FROM Tools.BDL_ImportLog
GROUP BY executed_by, environment, entity_type
ORDER BY executed_by, environment;
```

**In-flight imports awaiting reconciliation** [sort:4] -- Shows SUBMITTED imports that have not yet been reconciled to a terminal state. Useful for operational troubleshooting when the BDL Import history page shows persistent active rows.

```sql
SELECT log_id, environment, entity_type, source_filename,
    executed_by, started_dttm, last_polled_dttm,
    DATEDIFF(MINUTE, started_dttm, GETDATE()) AS minutes_since_start
FROM Tools.BDL_ImportLog
WHERE is_complete = 0
    AND status = 'SUBMITTED'
ORDER BY started_dttm DESC;
```

  - **Tools.ServerConfig**: [sort:1] Parent table. server_config_id references ServerConfig.config_id. Identifies which environment and server configuration was used for the import. The environment column is denormalized from ServerConfig for convenience.
  - **Future Template Table**: [sort:2] template_id is reserved for a future column mapping template table. When templates are implemented, this FK will link to the saved template used for the import. NULL indicates an ad-hoc mapping was used.


### BDL_ImportTemplate

Saved column mapping templates for BDL Import. One row per template storing a reusable mapping between source file column headers and BDL element names. Templates are entity-type specific and visible to all users. The creator or an admin can update or deactivate a template. Applied templates perform case-insensitive header matching against the current file, mapping only columns that exist in both the template and the uploaded file.

**Data Flow:** Templates are created from the BDL Import page Step 4 (Map Columns) via the Save Template button, which captures the current column mapping as JSON. The template list API endpoint returns all active templates for the selected entity type, displayed in the right column of the BDL Import page. When a user applies a template, the JS performs case-insensitive header matching against the current file and populates the column mapping. Templates can be updated by their creator or an admin via the slideout preview panel. Deactivation sets is_active = 0 rather than deleting the row. The template_id is referenced by BDL_ImportLog.template_id when a template-based import is executed.

**Case-Insensitive Header Matching:** [sort:1] When a template is applied to a new file, the mapping uses case-insensitive comparison between the template source column names and the current file headers. This accommodates vendor files where header casing may vary between exports while the column structure remains the same. Columns that exist in the template but not in the file are silently skipped — the user can manually map any remaining fields.

**Ownership Model:** [sort:2] Any authenticated user can create templates and all templates are visible to all users regardless of department or RBAC tier. Update and delete operations are restricted to the template creator or users with admin tier on the BDL Import page. Non-owners who want to modify a template must save a new copy under a different name.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| template_id (IDENTITY) | int | No | IDENTITY | Identity primary key. |
| entity_type | varchar(60) | No | — | BDL entity type this template applies to. Matches Catalog_BDLFormatRegistry.entity_type. Templates are scoped to a single entity type — a PHONE template cannot be used for CONSUMER_TAG imports. |
| template_name | varchar(100) | No | — | User-defined name for the template. Must be unique within the entity type. Displayed in the template list and slideout preview. |
| description | varchar(500) | Yes | — | Optional user-provided description of the template. Provides context on the file layout or vendor format the template was built for. |
| column_mapping | varchar(MAX) | No | — | JSON object storing source-to-element field mappings. Keys are source file column headers, values are BDL element names. Applied via case-insensitive header matching — only columns present in both the template and the current file are mapped. |
| is_active | bit | No | 1 | Whether this template is active. 0 = deactivated (soft delete), 1 = active (default). Deactivated templates are excluded from the template list but retained for audit. |
| created_by | varchar(100) | No | suser_sname() | AD username of the user who created the template. Uses FAC\\username format from the authenticated session. Determines ownership for update and delete permissions. |
| created_dttm | datetime | No | getdate() | When the template was created. |
| modified_by | varchar(100) | Yes | — | Who last modified the template. NULL if never modified. |
| modified_dttm | datetime | Yes | — | When the template was last modified. NULL if never modified. |

  - **PK_BDL_ImportTemplate** (CLUSTERED): template_id -- PRIMARY KEY
  - **UQ_BDL_ImportTemplate_entity_template** (NONCLUSTERED): entity_type, template_name

  - **BDL_ImportLog**: [sort:1] BDL_ImportLog.template_id references this table when a template-based import is executed. The template_id provides audit trail linkage between an import and the mapping template that was used. NULL template_id in the log indicates an ad-hoc mapping.
  - **Catalog_BDLFormatRegistry**: [sort:2] entity_type corresponds to Catalog_BDLFormatRegistry.entity_type. No physical foreign key — the entity type serves as a logical scoping filter. Templates are only presented when the user selects a matching entity type in the BDL Import wizard.


### Catalog_ApiRegistry

REST API endpoint catalog containing one row per path and HTTP method combination. Parsed from OpenAPI 3.0 YAML specification files. Supports multi-product cataloging via product_name column. Links to Catalog_ApiSchemaRegistry via request_schema and response_schema for field-level detail.

**Data Flow:** Populated by a Python parsing script that reads OpenAPI 3.0 YAML specification files and generates INSERT statements. Consumed by modules that need to discover available API endpoints for automation features.

**Operation ID Not Unique:** [sort:1] The OpenAPI spec reuses the same operationId across different paths. For example, saveImage appears on four paths (accounts, consumers, creditors, receivers). The unique constraint is on spec_version + endpoint_path + http_method, not on operation_id. Queries filtering by operation_id should expect multiple rows.

**Operation Type Classification:** [sort:2] The operation_type column is derived during import by pattern-matching the operationId: create/add/save/assign/import map to CREATE, retrieve/get/list/find map to RETRIEVE, update/modify map to UPDATE, delete/remove/unassign map to DELETE, search maps to SEARCH, and everything else maps to ACTION. ACTION captures non-CRUD operations like status updates, batch triggers, and workflow actions.

**Multi-Product Design:** [sort:3] The product_name column enables cataloging APIs from multiple products in the same table. Queries should always filter on product_name and spec_version to scope results to a specific product release.

**Schema Linkage Pattern:** [sort:4] The request_schema and response_schema columns contain model object names that link to Catalog_ApiSchemaRegistry.schema_name. This is a string-based link, not a foreign key, because the relationship is many-to-many (multiple endpoints share schemas) and some endpoints reference schemas that have no properties (service infrastructure types). Join on spec_version + schema_name for correct results.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| endpoint_id (IDENTITY) | int | No | IDENTITY | Identity primary key. |
| spec_version | varchar(30) | No | — | OpenAPI spec version identifier. No default constraint — every insert must explicitly specify. |
| product_name | varchar(50) | No | — | Source product name. Enables future multi-product cataloging. |
| resource_tag | varchar(50) | No | — | OpenAPI tag identifying the resource group this endpoint belongs to. |
| endpoint_path | varchar(200) | No | — | URL path template with placeholders for path parameters. |
| http_method | varchar(10) | No | — | HTTP verb: GET, POST, PUT, or DELETE. |
| operation_id | varchar(100) | No | — | OpenAPI operationId. Not guaranteed unique — some operations share the same ID across different paths. |
| summary | varchar(200) | Yes | — | Short one-line summary from the spec. |
| description | varchar(MAX) | Yes | — | Full description from the spec. May contain HTML markup. |
| operation_type | varchar(20) | Yes | — | Classified CRUD type derived from operationId patterns during import: CREATE, RETRIEVE, UPDATE, DELETE, SEARCH, or ACTION. |
| request_content_type | varchar(60) | Yes | — | Request MIME type. NULL for endpoints with no request body. |
| request_schema | varchar(80) | Yes | — | Schema name for the request body model object. Links to Catalog_ApiSchemaRegistry. NULL when no request body. |
| response_content_type | varchar(60) | Yes | — | Response MIME type for successful responses. NULL for 204 No Content responses. |
| response_schema | varchar(80) | Yes | — | Schema name for the successful response model object. Links to Catalog_ApiSchemaRegistry. |
| response_is_array | bit | No | 0 | Whether the successful response returns an array of the schema type. |
| path_params | varchar(500) | Yes | — | Comma-separated list of path parameter names. |
| query_params | varchar(500) | Yes | — | Comma-separated list of query parameter names. |
| path_param_count | smallint | No | 0 | Number of path parameters on this endpoint. |
| query_param_count | smallint | No | 0 | Number of query parameters on this endpoint. |
| is_deprecated | bit | No | 0 | Whether the endpoint is marked deprecated in the spec. |
| api_version | smallint | Yes | — | FICO API version number extracted from the content type. Values 1 through 4 observed in current spec. |

  - **PK_Catalog_ApiRegistry** (CLUSTERED): endpoint_id -- PRIMARY KEY
  - **IX_Catalog_ApiRegistry_Schema** (NONCLUSTERED): request_schema, response_schema [includes: endpoint_path, http_method, operation_id]
  - **IX_Catalog_ApiRegistry_Tag** (NONCLUSTERED): resource_tag, spec_version [includes: operation_id, http_method, summary]
  - **UQ_Catalog_ApiRegistry_Endpoint** (NONCLUSTERED): spec_version, endpoint_path, http_method

**Endpoint count by resource group** [sort:1] -- Overview of the API surface area showing how many endpoints exist per resource tag with CRUD breakdown.

```sql
SELECT resource_tag, COUNT(*) AS endpoints,
    SUM(CASE WHEN operation_type = 'CREATE' THEN 1 ELSE 0 END) AS creates,
    SUM(CASE WHEN operation_type = 'RETRIEVE' THEN 1 ELSE 0 END) AS retrieves,
    SUM(CASE WHEN operation_type = 'UPDATE' THEN 1 ELSE 0 END) AS updates,
    SUM(CASE WHEN operation_type = 'DELETE' THEN 1 ELSE 0 END) AS deletes,
    SUM(CASE WHEN is_deprecated = 1 THEN 1 ELSE 0 END) AS deprecated
FROM Tools.Catalog_ApiRegistry
WHERE spec_version = '11.1.0.1.6'
GROUP BY resource_tag
ORDER BY endpoints DESC;
```

**Find endpoints for a resource with request/response detail** [sort:2] -- Shows all endpoints for a given resource tag with their schemas. Replace the tag value as needed.

```sql
SELECT http_method, operation_id, summary, endpoint_path, 
    request_schema, response_schema, response_is_array
FROM Tools.Catalog_ApiRegistry
WHERE resource_tag = 'tags'
    AND spec_version = '11.1.0.1.6'
    AND is_deprecated = 0
ORDER BY endpoint_path, http_method;
```

**Full endpoint detail with request body fields** [sort:3] -- Joins to the schema registry to show the complete request body structure for an endpoint. Replace the operation_id as needed.

```sql
SELECT r.endpoint_path, r.http_method, r.summary,
    s.property_name, s.property_type, s.ref_schema, 
    s.is_required, s.is_read_only,
    LEFT(s.property_description, 120) AS description_preview
FROM Tools.Catalog_ApiRegistry r
INNER JOIN Tools.Catalog_ApiSchemaRegistry s
    ON r.spec_version = s.spec_version
    AND r.request_schema = s.schema_name
WHERE r.operation_id = 'createConsumerAccountCase'
    AND r.spec_version = '11.1.0.1.6'
ORDER BY s.sort_order;
```

  - **Catalog_ApiSchemaRegistry**: [sort:1] Links via request_schema and response_schema to schema_name. An endpoint's request body structure is defined by the schema matching request_schema. The response structure is defined by response_schema. When response_is_array is 1, the response returns a list of that schema type. Some endpoints have NULL for both (e.g., DELETE operations with no body and 204 responses).


### Catalog_ApiSchemaRegistry

REST API schema property catalog containing one row per property within each model object. Parsed from the components/schemas section of OpenAPI 3.0 YAML specification files. Schema descriptions and property counts are denormalized onto each property row to avoid a third table. Links to Catalog_ApiRegistry via schema name.

**Data Flow:** Populated by the same Python parsing script that populates Catalog_ApiRegistry, reading model object definitions from the components/schemas section of the OpenAPI YAML. Consumed by modules that need field-level detail for API request construction and response parsing.

**Denormalized Schema Metadata:** [sort:1] Schema-level fields (schema_description, schema_property_count) are repeated on every property row rather than stored in a separate header table. This avoids a third table while keeping queries simple. The trade-off is repeated descriptions across all property rows for a given schema — minimal storage cost.

**Schema Cross-References:** [sort:2] When a property is a complex type rather than a primitive, property_type is NULL and ref_schema contains the referenced schema name. When a property is an array of complex types, is_array is 1 and ref_schema contains the item schema. This enables traversing the full object graph by following ref_schema links recursively.

**Read-Only Detection:** [sort:3] The is_read_only flag is derived by text-matching READ-ONLY in the property description during import. This identifies system-generated fields that should not be included in POST/PUT request bodies. Not all read-only fields are explicitly marked in the spec, so this is a best-effort flag.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| schema_property_id (IDENTITY) | int | No | IDENTITY | Identity primary key. |
| spec_version | varchar(30) | No | — | OpenAPI spec version identifier. Must match values in Catalog_ApiRegistry. |
| product_name | varchar(50) | No | — | Source product name. Must match values in Catalog_ApiRegistry. |
| schema_name | varchar(80) | No | — | Model object name from the OpenAPI spec. This is the join key to Catalog_ApiRegistry request_schema and response_schema columns. |
| schema_description | varchar(500) | Yes | — | Schema-level description. Denormalized — repeated on every property row for query convenience. |
| schema_property_count | smallint | No | — | Total number of properties in this schema. Denormalized — repeated on every property row. |
| property_name | varchar(80) | No | — | JSON property name as it appears in API request and response payloads. |
| property_type | varchar(20) | Yes | — | Data type: string, integer, boolean, number, array, or object. NULL when the type is a schema reference. |
| property_format | varchar(30) | Yes | — | OpenAPI format qualifier such as date-time or int64. NULL when not specified. |
| property_description | varchar(MAX) | Yes | — | Full property description from the spec. Often includes the underlying DM database column name in parentheses. |
| ref_schema | varchar(80) | Yes | — | Referenced schema name when this property is a complex type or array of complex types. NULL for primitive types. |
| is_array | bit | No | 0 | Whether this property is an array type. |
| is_required | bit | No | 0 | Whether this property is listed in the schema required array. |
| is_read_only | bit | No | 0 | Whether the property description indicates READ-ONLY. Derived during import by text matching. |
| default_value | varchar(100) | Yes | — | Default value if specified in the spec. |
| sort_order | smallint | No | — | Ordinal position of this property within its parent schema. 1-based. |

  - **PK_Catalog_ApiSchemaRegistry** (CLUSTERED): schema_property_id -- PRIMARY KEY
  - **IX_Catalog_ApiSchemaRegistry_RefSchema** (NONCLUSTERED): ref_schema [includes: schema_name, property_name]
  - **IX_Catalog_ApiSchemaRegistry_Schema** (NONCLUSTERED): schema_name, spec_version [includes: property_name, property_type, ref_schema]
  - **UQ_Catalog_ApiSchemaRegistry_Property** (NONCLUSTERED): spec_version, schema_name, property_name

**Schema property detail** [sort:1] -- Shows all properties for a given schema with types and descriptions. Replace schema name as needed.

```sql
SELECT property_name, property_type, ref_schema, 
    is_required, is_read_only, is_array,
    LEFT(property_description, 150) AS description_preview
FROM Tools.Catalog_ApiSchemaRegistry
WHERE schema_name = 'ConsumerAccountCaseRequestRM'
    AND spec_version = '11.1.0.1.6'
ORDER BY sort_order;
```

**Find schemas that reference a given schema** [sort:2] -- Discovers which model objects contain references to a specific schema — useful for understanding the object graph.

```sql
SELECT schema_name, property_name, is_array
FROM Tools.Catalog_ApiSchemaRegistry
WHERE ref_schema = 'ReferenceRM'
    AND spec_version = '11.1.0.1.6'
ORDER BY schema_name, sort_order;
```

**Properties containing DM column names** [sort:3] -- Many property descriptions include the underlying DM database column name in parentheses. This query finds them for cross-referencing with crs5_oltp schema.

```sql
SELECT schema_name, property_name, 
    LEFT(property_description, 200) AS description_preview
FROM Tools.Catalog_ApiSchemaRegistry
WHERE property_description LIKE '%(%_%)%'
    AND spec_version = '11.1.0.1.6'
ORDER BY schema_name, sort_order;
```

  - **Catalog_ApiRegistry**: [sort:1] Referenced by Catalog_ApiRegistry.request_schema and response_schema. Multiple endpoints may share the same schema. Join on spec_version + schema_name.
  - **Self-referencing via ref_schema**: [sort:2] Properties with ref_schema values reference other schemas in the same table. This creates a graph of schema relationships. For example, AREventRM has properties referencing ActionResultCodeRM, ConsumerAccountIdentifierRM, and Consumer_Contact_Log. Following these links recursively reveals the full data structure.


### Catalog_BDLElementRegistry

BDL element catalog containing one row per element within each entity type. Parsed from XSD schema definition files. Element names correspond directly to DM database column names in crs5_oltp. Excludes nullify_fields structural elements. Child table of Catalog_BDLFormatRegistry via foreign key on spec_version and type_name.

**Data Flow:** Base structure populated by the BDL XSD parsing script. Enrichment columns (table_column, lookup_table, is_not_nullifiable, is_primary_id, field_description) populated by a separate enrichment script that parses the BDL Import/Export Interface Definition Excel workbook and matches rows to XSD elements by element name overlap scoring. Consumed by modules that perform vendor file column-mapping and BDL XML construction.

**Dual Data Sources:** [sort:1] This table combines data from two sources: the XSD schema definitions (element_name, data_type, is_required, is_collection, max_length) and the Excel interface definition (table_column, lookup_table, is_not_nullifiable, is_primary_id, field_description). XSD data covers all elements. Excel enrichment covers the data entity fields but not wrapper/container references.

**XSD Required vs Import Required:** [sort:2] The is_required column reflects XSD minOccurs and is almost always 0 (false) — the XSD is permissive by design. The is_not_nullifiable column from the Excel reflects practical import requirements: fields that must have values for the import to succeed, or that cannot be cleared via nullify_fields. These are the fields that matter for building import files.

**Collection Elements:** [sort:3] Elements with is_collection = 1 are child entity references in wrapper/container types. Their data_type values are BDL complexType names (e.g., bdl_cnsmr_phn_data_type) rather than primitive types. These elements define the BDL XML hierarchy — which entities can appear within each operational transaction. Query them to discover valid entity nesting.

**Table Column vs Element Name:** [sort:4] The table_column enrichment column is only populated when the DM database column name differs from the BDL XML element name. When NULL, the element_name is the column name. Common differences include reference code fields where the XML uses a _val_txt suffix but the database column uses a _cd suffix.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| element_id (IDENTITY) | int | No | IDENTITY | Identity primary key. |
| format_id | int | No | — | FK to Catalog_BDLFormatRegistry.format_id. Integer-based link to the parent entity type, replacing the composite (spec_version, type_name) join. The spec_version and type_name columns are retained as informational context. |
| spec_version | varchar(30) | No | — | XSD spec version identifier. Foreign key to Catalog_BDLFormatRegistry. |
| type_name | varchar(80) | No | — | Parent entity complexType name. Foreign key to Catalog_BDLFormatRegistry. |
| element_name | varchar(80) | No | — | XSD element name. For data entities, corresponds to the DM database column name. For container types, references child entity type names. |
| display_name | varchar(100) | Yes | — | Human-readable field name for display in the column mapping UI. Shown alongside or in place of the technical element_name to help users identify fields without needing to know DM column names. NULL values fall back to element_name display. |
| data_type | varchar(80) | Yes | — | Data type with xs: prefix stripped. Primitive types: string, long, decimal, dateTime, int, short, boolean, date. Non-primitive values reference other BDL complexType names for container/child entity relationships. |
| is_required | bit | No | 1 | Whether the element is required per XSD minOccurs. Note: XSD requirements are structural minimums — practical import requirements are determined by DM business logic and may differ. |
| is_collection | bit | No | 0 | Whether the element has maxOccurs="unbounded", indicating it is a child entity reference that can appear multiple times in the XML. Primarily found on container types in bdl_import_export.xsd. |
| max_length | int | Yes | — | Maximum string length from XSD maxLength restriction. NULL for non-string types or when no restriction is specified. |
| table_column | varchar(80) | Yes | — | DM database column name from the Excel interface definition. NULL when not enriched or when the table column matches the element name. Only populated when the names differ. |
| lookup_table | varchar(60) | Yes | — | Reference table containing valid values for this element. From the Excel interface definition Look Up Table column. |
| is_not_nullifiable | bit | No | 0 | Whether this element cannot be included in nullify_fields during BDL update operations. Sourced from the Excel Not Nullifiable Columns sheets. Elements marked not-nullifiable are typically identifiers or required business fields. |
| is_primary_id | bit | No | 0 | Whether this element is a system-generated primary key identifier. These are auto-assigned by DM and not user-supplied during import. Sourced from the Excel Not Nullifiable Columns Primary ID column. |
| is_visible | bit | No | 1 | Whether this element is shown to users in the BDL Import column mapping UI. 1 = visible (default), 0 = hidden. System-generated fields, unreliable identifiers, and internal DM fields should be hidden to prevent user errors. Does not affect the catalog's completeness — hidden elements remain in the spec but are excluded from the import picker. |
| is_import_required | bit | No | 0 | Whether this element must be mapped for a BDL import to succeed. 0 = optional (default), 1 = required. Reflects practical DM import requirements as determined by operational experience, distinct from is_required (XSD structural minimum) and is_not_nullifiable (cannot be cleared on update). Populated based on team review of each entity type. |
| is_conditional_eligible | bit | No | 0 | Identifies fields eligible for conditional value assignment during BDL Import. When set to 1, the FIXED_VALUE mapping UI offers a Conditional mode where this field's value can vary per row based on a trigger column from the uploaded file, rather than being applied as a blanket fixed value to all rows. Fields with 0 (default) use the standard blanket assignment only. Currently set on tag_shrt_nm for CONSUMER_TAG and ACCOUNT_TAG entities. |
| field_description | varchar(500) | Yes | — | Human-readable field description from the Excel interface definition. Supplements the XSD structural data with business context. |
| import_guidance | varchar(500) | Yes | — | Operational guidance text displayed during BDL import to help users fill in the field correctly. Examples: "Required numeric value — enter 0 if not in source data" for phone quality score, "Optional — defaults to current timestamp if blank" for tag assignment date. Separate from field_description which documents what the field is. NULL when no special import guidance is needed. |
| sort_order | smallint | No | — | Ordinal position of this element within its parent entity. 1-based. |

  - **PK_Catalog_BDLElementRegistry** (CLUSTERED): element_id -- PRIMARY KEY
  - **IX_Catalog_BDLElementRegistry_ElementName** (NONCLUSTERED): element_name [includes: type_name, data_type]
  - **IX_Catalog_BDLElementRegistry_FormatId** (NONCLUSTERED): format_id [includes: element_name, data_type, is_visible, is_import_required]
  - **IX_Catalog_BDLElementRegistry_TypeName** (NONCLUSTERED): type_name, spec_version [includes: element_name, data_type, is_required, max_length]
  - **UQ_Catalog_BDLElementRegistry_Element** (NONCLUSTERED): spec_version, type_name, element_name

**Foreign Keys:**

  - **FK_Catalog_BDLElementRegistry_Format**: format_id -> Tools.Catalog_BDLFormatRegistry.format_id

**Entity fields with enrichment data** [sort:1] -- Shows all elements for a BDL entity including Excel enrichment. Replace entity_type value as needed.

```sql
SELECT e.element_name, e.data_type, e.is_required, e.max_length,
    e.table_column, e.lookup_table, e.is_not_nullifiable, e.is_primary_id,
    LEFT(e.field_description, 120) AS description_preview
FROM Tools.Catalog_BDLElementRegistry e
INNER JOIN Tools.Catalog_BDLFormatRegistry f
    ON e.spec_version = f.spec_version AND e.type_name = f.type_name
WHERE f.entity_type = 'PHONE'
    AND f.spec_version = '11.1.0.1.6'
ORDER BY e.sort_order;
```

**Required fields for BDL import** [sort:2] -- Shows fields that are practically required for import (not-nullifiable or primary IDs). This is the foundation for the column-mapping UI validation.

```sql
SELECT f.entity_type, e.element_name, e.is_not_nullifiable, e.is_primary_id,
    e.lookup_table, LEFT(e.field_description, 100) AS description_preview
FROM Tools.Catalog_BDLElementRegistry e
INNER JOIN Tools.Catalog_BDLFormatRegistry f
    ON e.spec_version = f.spec_version AND e.type_name = f.type_name
WHERE (e.is_not_nullifiable = 1 OR e.is_primary_id = 1)
    AND f.spec_version = '11.1.0.1.6'
ORDER BY f.entity_type, e.sort_order;
```

**Fields with lookup table references** [sort:3] -- Shows elements that reference DM lookup tables for valid values. Useful for building validation dropdowns in the import UI.

```sql
SELECT f.entity_type, e.element_name, e.lookup_table,
    LEFT(e.field_description, 100) AS description_preview
FROM Tools.Catalog_BDLElementRegistry e
INNER JOIN Tools.Catalog_BDLFormatRegistry f
    ON e.spec_version = f.spec_version AND e.type_name = f.type_name
WHERE e.lookup_table IS NOT NULL
    AND f.spec_version = '11.1.0.1.6'
ORDER BY f.entity_type, e.sort_order;
```

**Discover BDL XML structure for an entity** [sort:4] -- Shows the full path from operational transaction wrapper to data entity, then lists the entity fields. This is the query pattern for constructing BDL import XML.

```sql
DECLARE @entity_type VARCHAR(60) = 'PHONE';
DECLARE @spec VARCHAR(30) = '11.1.0.1.6';

-- Step 1: Find which wrapper contains this entity
SELECT 'Wrapper' AS step, w.type_name AS wrapper, we.element_name AS entity_ref, we.data_type
FROM Tools.Catalog_BDLFormatRegistry w
INNER JOIN Tools.Catalog_BDLElementRegistry we
    ON w.spec_version = we.spec_version AND w.type_name = we.type_name
INNER JOIN Tools.Catalog_BDLFormatRegistry f
    ON we.data_type = f.type_name AND f.spec_version = we.spec_version
WHERE f.entity_type = @entity_type AND w.spec_version = @spec;

-- Step 2: List the entity fields
SELECT 'Field' AS step, e.element_name, e.data_type, e.is_not_nullifiable, e.is_primary_id,
    e.lookup_table, e.max_length
FROM Tools.Catalog_BDLElementRegistry e
INNER JOIN Tools.Catalog_BDLFormatRegistry f
    ON e.spec_version = f.spec_version AND e.type_name = f.type_name
WHERE f.entity_type = @entity_type AND f.spec_version = @spec
ORDER BY e.sort_order;
```

  - **Catalog_BDLFormatRegistry**: [sort:1] Child table. Each element belongs to exactly one format entity via foreign key on spec_version + type_name.


### Catalog_BDLFormatRegistry

BDL bulk data load format catalog containing one row per entity type. Parsed from XSD schema definition files. Each entity type represents a DM data entity that can be imported via BDL. Parent table for Catalog_BDLElementRegistry.

**Data Flow:** Populated by a Python parsing script that reads BDL XSD schema definition files from DM release packages. Each row represents a BDL data entity that can be imported via bulk data load. Consumed by modules that perform BDL import automation — vendor file upload, column mapping, and XML construction.

**Folder Column as Hierarchy Indicator:** [sort:1] The folder column captures the subdirectory path within the BDL XSD folder (consumer, consumer/account, payment/settlement, etc.). This provides an at-a-glance view of the entity hierarchy without needing to parse the wrapper types in bdl_import_export.xsd.

**Wrapper and Container Types:** [sort:2] The format registry includes wrapper types from bdl_import_export.xsd (e.g., consumer_operational_transaction_data_type, account_operational_transaction_data_type) that have NULL entity_type. These define which data entities belong to each BDL operational transaction. Their child elements in the element registry have is_collection = 1 and data_type values referencing the actual data entity type names.

**Nullify Fields Support:** [sort:3] Entities with has_nullify_fields = 1 support the BDL nullification mechanism — a way to explicitly clear field values during update operations. The nullify_fields structural element itself is excluded from the element registry since it is not a data element.

**Batch ID Construction:** [sort:4] The BDL XML batch_id_txt header element maps to DM file_rgstry_dtl.btch_idntfr_txt, which is VARCHAR(32). Build-BDLXml constructs this value as XF_{batch_abbreviation}_{yyyyMMddHHmmss}, using the batch_abbreviation column to keep the total within the 32-character limit. If batch_abbreviation is NULL, the entity_type is truncated to 14 characters as a fallback.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| format_id (IDENTITY) | int | No | IDENTITY | Identity primary key. |
| spec_version | varchar(30) | No | — | XSD spec version identifier. No default constraint — every insert must explicitly specify. |
| entity_type | varchar(60) | Yes | — | Entity type name from the XSD fixed type attribute. NULL for wrapper, container, and utility types defined in bdl_import_export.xsd. |
| type_name | varchar(80) | No | — | XSD complexType name. This is the join key to Catalog_BDLElementRegistry. |
| xsd_filename | varchar(60) | No | — | Source XSD filename. |
| folder | varchar(30) | Yes | — | Subdirectory path within the BDL XSD folder. Indicates the entity hierarchy: consumer, consumer/account, payment/settlement, etc. NULL for root-level files. |
| element_count | smallint | No | — | Number of data elements defined in this entity type. Excludes the nullify_fields structural element. |
| has_parent_ref | bit | No | 0 | Whether this entity has a bdl_parent_id attribute indicating a parent-child relationship. |
| has_nullify_fields | bit | No | 0 | Whether this entity supports field nullification via the nullify_fields element. A BDL-specific feature for clearing field values on update. |
| is_active | bit | No | 1 | Whether this entity type is active and available for use. 1 = active (default), 0 = deactivated. Deactivated entities do not appear in entity selection for any user including admin. Deactivation cascades naturally through query filtering — AccessConfig and AccessFieldConfig rows referencing a deactivated entity become unreachable without requiring updates to those tables. |
| action_type | varchar(20) | No | 'FILE_MAPPED' | Controls which mapping UI is rendered for each entity type in the BDL Import wizard. FILE_MAPPED uses column-to-field drag-and-drop mapping panels. FIXED_VALUE presents direct value entry fields where the user enters uniform values applied to all rows (used for tagging operations). HYBRID is reserved for future entities requiring a mix of both approaches. CHECK constraint enforces valid values. Defaults to FILE_MAPPED. |
| entity_key | varchar(30) | Yes | — | Identifies which DM identifier field drives the import for this entity type. CONSUMER entities use cnsmr_idntfr_agncy_id as the key. ACCOUNT entities use cnsmr_accnt_idntfr_agncy_id. OTHER covers specialized entities that do not fit either pattern. Used by the BDL Import wizard to group entity type cards into visual sections on the selection screen. NULL for wrapper and deferred entity types not yet classified. |
| batch_abbreviation | varchar(14) | Yes | — | Short abbreviation used in the BDL XML batch_id_txt header element. The batch_id_txt value is constructed as XF_{abbreviation}_{yyyyMMddHHmmss} and must not exceed 32 characters, which is the column limit on the DM file_rgstry_dtl.btch_idntfr_txt column. Maximum 14 characters. Editable through the admin catalog modal. Falls back to a truncated entity_type if NULL. |
| operational_transaction_type | varchar(50) | Yes | — | The operational_transaction_type value emitted in the operational_transaction_type element of the BDL XML header for this entity type. The XML builder reads this value directly from the catalog. |

  - **PK_Catalog_BDLFormatRegistry** (CLUSTERED): format_id -- PRIMARY KEY
  - **IX_Catalog_BDLFormatRegistry_EntityType** (NONCLUSTERED): entity_type, spec_version [includes: type_name, element_count, has_parent_ref, has_nullify_fields]
  - **UQ_Catalog_BDLFormatRegistry_TypeName** (NONCLUSTERED): spec_version, type_name

**Check Constraints:**

  - **CK_Catalog_BDLFormatRegistry_action_type**: `([action_type]='HYBRID' OR [action_type]='FIXED_VALUE' OR [action_type]='FILE_MAPPED')`
  - **CK_Catalog_BDLFormatRegistry_entity_key**: `([entity_key]='OTHER' OR [entity_key]='ACCOUNT' OR [entity_key]='CONSUMER')`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| action_type | FILE_MAPPED | Default. User maps source file columns to BDL fields via drag-and-drop panels. Used for entity types where field values come from the uploaded file. | 1 |
| action_type | FIXED_VALUE | User enters values directly rather than mapping from file columns. The identifier comes from the file, but payload values are entered by the user and applied uniformly to every row. Used for tagging operations. | 2 |
| action_type | HYBRID | Reserved for future use. Combination of file-mapped and manually entered fields. | 3 |
| entity_key | CONSUMER | Entity uses cnsmr_idntfr_agncy_id as the import key. Displayed in the Consumer section of the entity selection grid. | 1 |
| entity_key | ACCOUNT | Entity uses cnsmr_accnt_idntfr_agncy_id as the import key. Displayed in the Account section of the entity selection grid. | 2 |
| entity_key | OTHER | Specialized entity that does not fit the consumer or account key pattern. Displayed in the Other section of the entity selection grid. | 3 |

**All BDL data entities** [sort:1] -- Lists importable BDL entity types excluding wrapper/container types.

```sql
SELECT entity_type, type_name, folder, element_count, has_parent_ref, has_nullify_fields
FROM Tools.Catalog_BDLFormatRegistry
WHERE spec_version = '11.1.0.1.6'
    AND entity_type IS NOT NULL
ORDER BY folder, entity_type;
```

**BDL operational transaction structure** [sort:2] -- Shows which data entities belong to each operational transaction type by querying the wrapper container elements.

```sql
SELECT f.type_name AS container, e.element_name AS entity_ref, e.data_type AS entity_type_name
FROM Tools.Catalog_BDLFormatRegistry f
INNER JOIN Tools.Catalog_BDLElementRegistry e
    ON f.spec_version = e.spec_version AND f.type_name = e.type_name
WHERE f.entity_type IS NULL
    AND f.folder IS NULL
    AND e.is_collection = 1
    AND f.spec_version = '11.1.0.1.6'
ORDER BY f.type_name, e.sort_order;
```

  - **Catalog_BDLElementRegistry**: [sort:1] Parent table. Each format has zero or more elements in Catalog_BDLElementRegistry linked by foreign key on spec_version + type_name.


### Catalog_CDLElementRegistry

CDL element catalog containing one row per element within each entity type. Parsed from XSD schema definition files. Element names correspond directly to DM database column names in crs5_oltp. Child table of Catalog_CDLFormatRegistry via foreign key on spec_version and type_name.

**Data Flow:** Populated alongside Catalog_CDLFormatRegistry by the CDL XSD parsing script. Element names correspond directly to DM database column names in crs5_oltp. Consumed by modules that need to discover available fields for CDL import/export operations.

**Element Names Are Column Names:** [sort:1] CDL element names map directly to crs5_oltp database column names. This is a key difference from BDL, where element names sometimes differ from table column names. CDL elements can be used directly for cross-referencing with the DM OLTP schema.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| element_id (IDENTITY) | int | No | IDENTITY | Identity primary key. |
| format_id | int | No | — | FK to Catalog_CDLFormatRegistry.format_id. Integer-based link to the parent entity type, replacing the composite (spec_version, type_name) join. The spec_version and type_name columns are retained as informational context. |
| spec_version | varchar(30) | No | — | XSD spec version identifier. Foreign key to Catalog_CDLFormatRegistry. |
| type_name | varchar(60) | No | — | Parent entity complexType name. Foreign key to Catalog_CDLFormatRegistry. |
| element_name | varchar(80) | No | — | XSD element name. Corresponds to the DM database column name. |
| display_name | varchar(100) | Yes | — | Human-readable field name for display in the column mapping UI. Shown alongside or in place of the technical element_name to help users identify fields without needing to know DM column names. NULL values fall back to element_name display. |
| data_type | varchar(30) | Yes | — | XSD data type with xs: prefix stripped. Common values: string, boolean, int, long, decimal, dateTime, short. |
| is_required | bit | No | 1 | Whether the element is required per XSD minOccurs. Derived from minOccurs: 0 means optional, 1 or unspecified means required. |
| is_visible | bit | No | 1 | Whether this element is shown to users in import/export UIs. 1 = visible (default), 0 = hidden. Mirrors the Catalog_BDLElementRegistry pattern for consistency across catalog tables. |
| is_import_required | bit | No | 0 | Whether this element must be mapped for a CDL import to succeed. 0 = optional (default), 1 = required. Mirrors the Catalog_BDLElementRegistry pattern for consistency across catalog tables. |
| max_length | int | Yes | — | Maximum string length from XSD maxLength restriction. NULL for non-string types or when no restriction is specified. |
| sort_order | smallint | No | — | Ordinal position of this element within its parent entity. 1-based. |

  - **PK_Catalog_CDLElementRegistry** (CLUSTERED): element_id -- PRIMARY KEY
  - **IX_Catalog_CDLElementRegistry_ElementName** (NONCLUSTERED): element_name [includes: type_name, data_type]
  - **IX_Catalog_CDLElementRegistry_FormatId** (NONCLUSTERED): format_id [includes: element_name, data_type, is_visible, is_import_required]
  - **IX_Catalog_CDLElementRegistry_TypeName** (NONCLUSTERED): type_name, spec_version [includes: element_name, data_type, is_required, max_length]
  - **UQ_Catalog_CDLElementRegistry_Element** (NONCLUSTERED): spec_version, type_name, element_name

**Foreign Keys:**

  - **FK_Catalog_CDLElementRegistry_Format**: format_id -> Tools.Catalog_CDLFormatRegistry.format_id

**Entity fields with types** [sort:1] -- Shows all elements for a given CDL entity type. Replace entity_type value as needed.

```sql
SELECT e.element_name, e.data_type, e.is_required, e.max_length
FROM Tools.Catalog_CDLElementRegistry e
INNER JOIN Tools.Catalog_CDLFormatRegistry f
    ON e.spec_version = f.spec_version AND e.type_name = f.type_name
WHERE f.entity_type = 'CREDITOR'
    AND f.spec_version = '11.1.0.1.6'
ORDER BY e.sort_order;
```

  - **Catalog_CDLFormatRegistry**: [sort:1] Child table. Each element belongs to exactly one format entity via foreign key on spec_version + type_name.


### Catalog_CDLFormatRegistry

CDL configuration data format catalog containing one row per entity type. Parsed from XSD schema definition files. Each entity type represents a DM configuration object that can be imported or exported via CDL. Parent table for Catalog_CDLElementRegistry.

**Data Flow:** Populated by a Python parsing script that reads CDL XSD schema definition files from DM release packages. Each row represents a CDL configuration entity type that can be imported or exported. Consumed by modules that perform CDL import/export automation and configuration management.

**Entity Types vs Sub-Types:** [sort:1] Most entities have an entity_type value from the XSD fixed type attribute (e.g., CREDITOR, ACTIONCODE). Some entries have NULL entity_type — these are sub-types, utility types, or abstract base types defined in shared XSD files like cdl_udp_field_type.xsd. The type_name column is always populated and serves as the primary identifier.

**Parent-Child Relationships:** [sort:2] Entities with has_parent_ref = 1 have a cdl_item_stgng_prnt_id attribute in the XSD, indicating they are child entities that reference a parent during import. For example, CREDITOR_CONFIGURATION is a child of CREDITOR. The parent relationship is not explicitly stored in this table — it is implied by the CDL import structure and documented in the DM interface definition.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| format_id (IDENTITY) | int | No | IDENTITY | Identity primary key. |
| spec_version | varchar(30) | No | — | XSD spec version identifier. No default constraint — every insert must explicitly specify. |
| entity_type | varchar(60) | Yes | — | Entity type name from the XSD fixed type attribute. NULL for sub-types and utility types that lack a type attribute. |
| type_name | varchar(60) | No | — | XSD complexType name. This is the join key to Catalog_CDLElementRegistry. |
| xsd_filename | varchar(60) | No | — | Source XSD filename within the CDL entity folder. |
| element_count | smallint | No | — | Number of data elements defined in this entity type. |
| has_parent_ref | bit | No | 0 | Whether this entity has a cdl_item_stgng_prnt_id attribute indicating a parent-child relationship. |
| is_active | bit | No | 1 | Whether this entity type is active and available for use. 1 = active (default), 0 = deactivated. Deactivated entities do not appear in entity selection for any user including admin. |

  - **PK_Catalog_CDLFormatRegistry** (CLUSTERED): format_id -- PRIMARY KEY
  - **IX_Catalog_CDLFormatRegistry_EntityType** (NONCLUSTERED): entity_type, spec_version [includes: type_name, element_count, has_parent_ref]
  - **UQ_Catalog_CDLFormatRegistry_TypeName** (NONCLUSTERED): spec_version, type_name

**All CDL entity types** [sort:1] -- Lists all CDL configuration entity types with their element counts and parent reference status.

```sql
SELECT entity_type, type_name, element_count, has_parent_ref, xsd_filename
FROM Tools.Catalog_CDLFormatRegistry
WHERE spec_version = '11.1.0.1.6'
    AND entity_type IS NOT NULL
ORDER BY entity_type;
```

  - **Catalog_CDLElementRegistry**: [sort:1] Parent table. Each format has zero or more elements in Catalog_CDLElementRegistry linked by foreign key on spec_version + type_name.


### EnvironmentConfig

Per-server configuration for Tools module operations. One row per tools-enabled target server, providing DM API connection details and dmfs file import paths. Child of dbo.ServerRegistry via server_id foreign key.

**Data Flow:** Rows are manually inserted when a new DM environment is configured. The BDL Import workflow reads this table to resolve the dmfs file path and database instance based on the user's environment selection. API URLs are resolved separately from dbo.ServerRegistry using the environment value. Future Tools pipelines (Payment, CDL, New Business) consume the same rows using their respective folder columns.

**Path Construction Pattern:** [sort:2] Full file paths are constructed by combining dmfs_base_path with the pipeline-specific folder column and a trailing backslash. For example, a BDL import path is dmfs_base_path + backslash + dmfs_bdl_folder + backslash. The folder columns have sensible defaults but are stored explicitly so paths remain configurable without code changes.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| config_id (IDENTITY) | int | No | IDENTITY | Identity primary key. |
| environment | varchar(20) | No | — | Denormalized environment from ServerRegistry (PROD, STAGE, TEST). Used as the primary lookup key when the UI environment selector resolves to a server configuration. |
| db_instance | varchar(50) | No | — | SQL Server instance name or AG listener for the crs5_oltp database in this environment. Used by validation and query operations that need to read DM reference tables. For standalone environments (TEST), this is the same as server_name. For AG environments (PROD, STAGE), this is the AG listener name. |
| dmfs_base_path | varchar(500) | No | — | Base UNC path for the DM file system import folder (e.g., \\\\dm-prod-app3\\e$\\dmfs\\import). Pipeline-specific subfolder columns are appended to construct full paths. |
| dmfs_bdl_folder | varchar(50) | No | 'bdl' | Subfolder name under dmfs_base_path for BDL import files. Default: bdl. |
| dmfs_cdl_folder | varchar(50) | No | 'cdl' | Subfolder name under dmfs_base_path for CDL import files. Default: cdl. |
| dmfs_payment_folder | varchar(50) | No | 'payments' | Subfolder name under dmfs_base_path for payment import files. Default: payments. |
| dmfs_newbusiness_folder | varchar(50) | No | 'newbusiness' | Subfolder name under dmfs_base_path for new business import files. Default: newbusiness. |
| is_active | bit | No | 1 | Whether this server configuration is active. 0 = disabled, 1 = enabled (default). |
| created_dttm | datetime | No | getdate() | When the configuration was created. |
| created_by | varchar(100) | No | suser_sname() | Who created the configuration. |
| modified_dttm | datetime | Yes | — | When the configuration was last modified. |
| modified_by | varchar(100) | Yes | — | Who last modified the configuration. |

  - **PK_ServerConfig** (CLUSTERED): config_id -- PRIMARY KEY

**Configuration by environment** [sort:1] -- Returns the full server configuration for a given environment. Primary query pattern for all Tools operations.

```sql
SELECT environment, db_instance, dmfs_base_path,
    dmfs_bdl_folder, dmfs_cdl_folder,
    dmfs_payment_folder, dmfs_newbusiness_folder
FROM Tools.EnvironmentConfig
WHERE environment = 'PROD'
    AND is_active = 1;
```


### sp_SyncColumnOrdinals

Aligns Object_Metadata column description sort_order values with actual sys.columns column_id ordinals. Compares active column description rows against the system catalog, updates misaligned sort_order values to match current column positions, and deactivates description rows for columns that no longer exist. Supports three scopes: single table (both parameters provided), all tables in a schema (@SchemaName only), or full database (no parameters). Returns a detail result set in single-table preview mode and a per-table summary in all other modes. Runs in preview mode by default.

**Preview-First Safety:** [sort:1] @PreviewOnly defaults to 1, requiring an explicit opt-in to apply changes. The preview output shows every proposed action (UPDATE or DEACTIVATE) with before and after sort_order values, plus a summary of aligned, misaligned, orphaned, and missing columns. This makes it safe to run exploratively against any table without risk.

**Orphan Handling:** [sort:2] When a column exists in Object_Metadata but not in sys.columns, the row is deactivated (is_active = 0) and sort_order is set to 0 rather than deleted. This preserves the documentation history while removing the orphan from active exports and reference pages.

**Missing Column Detection:** [sort:3] Columns found in sys.columns with no matching active Object_Metadata description row are reported in the output as informational. The proc does not auto-generate description rows — that remains a manual enrichment task to ensure content quality.

**Parameters:**

| Parameter | Type | Direction | Default | Description |
| --- | --- | --- | --- | --- |
| @SchemaName | varchar(128) | IN |  |  |
| @ObjectName | varchar(128) | IN |  |  |
| @PreviewOnly | bit | IN |  |  |

  - **Object_Metadata**: [sort:1] Reads and updates dbo.Object_Metadata rows where property_type is description and column_name is populated. Only active rows (is_active = 1) are evaluated. Sort_order updates and deactivations set modified_dttm and modified_by via GETDATE() and SUSER_SNAME().


### parse-css.js

Node.js helper script invoked as a subprocess from PowerShell to parse CSS source files into structured JSON. Wraps PostCSS 8.5.12 and postcss-selector-parser 7.1.1 for AST extraction with full line-number metadata and decomposed selector trees. Output drives the CSS extraction populator in the Asset_Registry parser pipeline.


### parse-js.js

Node.js helper script invoked as a subprocess from PowerShell to parse JavaScript source files into structured JSON. Wraps Acorn 8.16.0 and acorn-walk 8.3.5 for AST extraction with full source position metadata. Output drives the JS extraction populator in the Asset_Registry parser pipeline.


### Populate-AssetRegistry-CSS.ps1

Asset_Registry parser pipeline component for CSS source files. Walks every CSS file in the Control Center codebase, parses each via the parse-css.js Node helper, and emits one Asset_Registry row per cataloged construct. Validates each row against CC_CSS_Spec.md rules and attaches drift codes for any deviation.


### Populate-AssetRegistry-HTML.ps1

Asset_Registry parser pipeline component for HTML markup embedded in PowerShell files. Walks every .ps1 and .psm1 file under the Control Center route and helper directories, identifies HTML-emitting constructs, and emits one Asset_Registry row per cataloged HTML construct. Validates each row against CC_HTML_Spec.md rules and attaches drift codes for any deviation.


### Populate-AssetRegistry-JS.ps1

Asset_Registry parser pipeline component for JavaScript source files. Walks every JS file in the Control Center codebase, parses each via the parse-js.js Node helper, and emits Asset_Registry rows for both JS code constructs and HTML markup found inside template strings. Validates each row against CC_JS_Spec.md rules and attaches drift codes for any deviation.


### Populate-AssetRegistry-PS.ps1

Asset_Registry parser pipeline component for PowerShell source files. Walks every .ps1 and .psm1 file under the xFACts PowerShell roots, parses each via the native PowerShell AST, and emits one Asset_Registry row per cataloged construct. Validates each row against CC_PS_Spec.md rules and attaches drift codes for any deviation.


### Resolve-AssetRegistryReferences.ps1

Cross-spec resolution phase of the Asset_Registry pipeline. Runs after the four populators have written DEFINITION and USAGE rows. Resolves every cross-spec USAGE row's source_file and scope against matching DEFINITION rows; emits edge-specific drift codes when references cannot be resolved, and a catch-all UNRESOLVED_REFERENCE code on any row that remains in the <pending> state after the resolve phase completes.


### xFACts-AssetRegistryFunctions.ps1

Shared function library for the Asset_Registry parser pipeline. Dot-sourced by every populator in the family after xFACts-OrchestratorFunctions.ps1. Centralizes row construction, drift code attachment, occurrence-index computation, registry loads, bulk insert, banner detection and parsing, file-header parsing, pre-built section list construction, and the generic AST visitor walker.

**Data Flow:** Reads dbo.Object_Registry to build the (file_name to registry_id) map used at bulk-insert time for foreign-key resolution. Reads dbo.Component_Registry joined to dbo.Object_Registry to build the (file_name to cc_prefix) map used by populators for prefix registry validation. Writes to dbo.Asset_Registry via SqlBulkCopy from a DataTable assembled from per-populator row collections. All reads and writes use the configured xFACts database connection inherited from xFACts-OrchestratorFunctions.ps1.

**Hybrid Drift Code Attachment:** [sort:1] Add-DriftCode validates each code against a per-populator master $script:DriftDescriptions hashtable; unknown codes are refused with a warning. Description text defaults to the master entry but can be overridden per-call with a -Context string for row-specific detail (e.g., a function name that fails its prefix check). Test-DriftCodesAgainstMasterTable runs at the output boundary before bulk insert as a final guardrail against typos and stale codes that escaped validation.

**Pre-Built Section List with Body-Line Ranges:** [sort:2] New-SectionList walks every block comment in a parsed file once at the start of per-file processing, identifies banner-shaped comments via Test-IsBannerComment, parses each via Get-BannerInfo, and produces a sorted list of section instances with body-line ranges (banner-end+1 to next-banner-start-1). Get-SectionForLine then provides O(n) line-to-section lookup during AST walking. Replaces the legacy running-state model that depended on walker-equals-source-order traversal — the pre-built list is correct under any walking order, including tree-order visitor walks where nodes at higher line numbers may be visited before nodes at lower line numbers.



# Object_Metadata: Tools
Source: dbo.Object_Metadata
Generated: 2026-07-22 05:21:08

## AccessConfig (Table)

### category #0

Operations

### data_flow #0

Rows are manually inserted to grant department-level access to specific tools and entity types. The BDL Import entity picker queries this table filtered by the logged-in user's department scope to determine which entity types to display. Admin tier users skip this check entirely and see all enabled entities from the catalog. Future tool types (CDL, Payment, API) use the same table with different tool_type values.

### description #0

Controls which tools and entity types are available for use, and which departments can access each one. Admin tier users on the Tools page bypass department filtering and see all enabled items. Non-admin users see only items explicitly granted to their department.

### design_note #1
Title: Admin Tier Bypass

Users with admin tier on the Tools page see all enabled entities regardless of AccessConfig rows. This table only filters non-admin users. The Applications team receives admin tier on the BDL Import page, so no AccessConfig rows are needed for them. Only departments with restricted access (e.g., Business Intelligence) require rows.

### design_note #2
Title: Column NULL Semantics

A NULL item_key means access to the tool type itself without sub-item granularity — used for tools like Drools Refresh that have no entity picker. A NULL department_scope would mean unrestricted access to all departments, but this is not the expected pattern — admin tier handles unrestricted access. Rows should always have a department_scope populated.

### module #0

Tools

### query #1
Title: Available BDL entities for a department
Description: Returns the BDL entity types accessible to a specific department. Join to Catalog_BDLFormatRegistry for display names and field details.

SELECT ac.item_key AS entity_type, f.type_name, f.folder, f.element_count
FROM Tools.AccessConfig ac
INNER JOIN Tools.Catalog_BDLFormatRegistry f
    ON f.entity_type = ac.item_key
    AND f.spec_version = '11.1.0.1.6'
WHERE ac.tool_type = 'BDL'
    AND ac.department_scope = 'business-intelligence'
    AND ac.is_active = 1
ORDER BY f.folder, f.entity_type;

### query #2
Title: All access grants by tool type
Description: Shows the complete access matrix across all departments and tool types.

SELECT tool_type, item_key, department_scope, is_active
FROM Tools.AccessConfig
ORDER BY tool_type, item_key, department_scope;

### relationship_note #1
Title: dbo.RBAC_DepartmentRegistry

Logical relationship. department_scope matches RBAC_DepartmentRegistry.department_key. No physical foreign key — validated at the application layer, consistent with the RBAC_RoleMapping pattern.

### relationship_note #2
Title: Tools.Catalog_BDLFormatRegistry

Logical relationship. For BDL tool_type rows, item_key corresponds to Catalog_BDLFormatRegistry.entity_type. No physical foreign key since AccessConfig spans multiple tool types and catalogs.

### relationship_note #3
Title: AccessFieldConfig

Parent table. AccessFieldConfig rows provide a field-level whitelist for department-scoped entity grants. When AccessFieldConfig rows exist for a config_id, only those fields are accessible to the department. No AccessFieldConfig rows means zero field access (strict whitelist). Admin tier users bypass both tables entirely.

### description / config_id #1

Identity primary key.

### description / created_by #7

Who created the access grant.

### description / created_dttm #6

When the access grant was created.

### description / department_scope #4

Department key this access grant applies to. Matches RBAC_DepartmentRegistry.department_key. Rows should always have a department_scope populated — unrestricted access is handled by admin tier bypass, not by NULL scope rows.

### description / is_active #5

Whether this access grant is active. 0 = disabled, 1 = enabled (default).

### description / item_key #3

Specific item within the tool type that access is being granted to. For BDL and CDL, this is the entity_type from the corresponding catalog table (e.g., PHONE, CONSUMER_TAG). NULL for tools that do not have sub-item granularity.

### description / modified_by #9

Who last modified the access grant.

### description / modified_dttm #8

When the access grant was last modified.

### description / tool_type #2

Identifies the tool or pipeline this access grant applies to. Values include BDL, CDL, PAYMENT, NEWBUSINESS, API, and other tool identifiers as they are added. No check constraint — values are open to accommodate future tools.

## AccessFieldConfig (Table)

### category #0

Operations

### data_flow #0

Rows are manually inserted when granting a department access to specific fields within a BDL entity type. The BDL Import entity-fields API endpoint queries this table for non-admin users, returning only fields that have an active whitelist row for the user's department. Admin tier users skip this check and see all visible fields from the catalog. The config_id foreign key links to AccessConfig, which provides the entity type and department scope context.

### description #0

Whitelist of BDL element fields accessible to a department for a specific entity type. Child of AccessConfig — each row grants access to one field within the parent entity grant. Admin tier users bypass this table entirely. When an AccessConfig row exists but has no AccessFieldConfig children, the department has zero field access to that entity (strict whitelist). Fields not in this table are invisible to the department in the column mapping UI.

### module #0

Tools

### relationship_note #1
Title: AccessConfig

Child table. config_id references AccessConfig.config_id. Each AccessFieldConfig row grants access to one element within the entity and department defined by the parent AccessConfig row. No child rows means zero field access (strict whitelist).

### relationship_note #2
Title: Catalog_BDLElementRegistry

element_name references element names from Catalog_BDLElementRegistry. No formal FK — the element catalog may be reloaded independently. Validation is enforced at the application layer during field access queries.

### description / config_id #2

FK to Tools.AccessConfig. Identifies the parent entity-level access grant this field whitelist belongs to.

### description / created_by #6

Who created the field grant.

### description / created_dttm #5

When the field grant was created.

### description / element_name #3

BDL element name being granted. Matches Catalog_BDLElementRegistry.element_name.

### description / field_config_id #1

Identity primary key.

### description / is_active #4

Whether this field grant is active. 0 = disabled, 1 = enabled (default).

### description / modified_by #8

Who last modified the field grant.

### description / modified_dttm #7

When the field grant was last modified.

## BDL_ImportLog (Table)

### category #0

Operations

### data_flow #0

A row is inserted when a user initiates a BDL import from the Control Center, initially with VALIDATING status. The status column is updated as the import progresses through the lifecycle: VALIDATING (data checks running), BUILDING (XML file being constructed), REGISTERED (file registered with DM via POST /fileregistry), SUBMITTED (import triggered via POST /fileregistry/{id}/bdlimport), COMPLETED (reconciliation confirmed DM terminal success), or FAILED (error at any stage or DM reported terminal failure). The column_mapping JSON is captured at validation time. The file_registry_id is populated after successful DM registration. After submission, the reconciliation helper in xFACts-Helpers.psm1 — invoked on demand by the /api/bdl-import/history endpoint — queries the target environment's dbo.File_Registry using the stored file_registry_id, writes back terminal status and record counts from the file_rgstry_cstm_dtl Dm_* metrics, and sets is_complete = 1 when DM-side processing reaches a terminal state. Rows are append-only — status updates modify the existing row but no rows are ever deleted.

### description #0

Audit trail for BDL import executions. One row per import capturing the full lifecycle from file upload and validation through XML construction, DM file registration, submission, and DM-side terminal state reconciliation. Tracks who executed each import, against which environment, for which entity type, and what the final DM outcome was.

### design_note #1
Title: Column Mapping Audit Trail

The column_mapping column stores a JSON representation of the field mapping used for the import — which source file columns were mapped to which BDL element names. This provides a complete audit trail of what was actually imported, regardless of whether a template was used. When a template is selected, the mapping is locked (read-only in the UI) and the template_id is also recorded.

### design_note #2
Title: Error Recovery Pattern

Failed imports require a new file with a new filename to be registered with DM — re-importing a previously registered file is not supported. A retry creates a new BDL_ImportLog row rather than updating the failed row. The failed row preserves the error context for diagnostics.

### design_note #3
Title: DM Import Status Confirmation

The SUBMITTED to COMPLETED/FAILED transition is driven by on-demand reconciliation, not a scheduled collector. The /api/bdl-import/history endpoint invokes Invoke-BDLImportLogReconcile in xFACts-Helpers.psm1, which groups non-terminal rows (is_complete = 0) by environment, resolves the target db_instance from Tools.EnvironmentConfig, and issues one batched query per environment against dbo.File_Registry using the stored file_registry_id. Terminal File_Registry status codes (5 = PROCESSED, 6 = FAILED, 7 = CANCELED, 8 = PARTIALLY_PROCESSED) drive the write-back — status is advanced to COMPLETED or FAILED, file_registry_status captures DM's detailed vocabulary, and record counts are sourced from file_rgstry_cstm_dtl Dm_* metrics. Rows that cannot be located in File_Registry after repeated lookups are flagged ORPHANED, typical after environment refreshes. is_complete = 1 stops further reconciliation attempts on terminal or orphaned rows. Frontend polling (GlobalConfig-driven interval) drives repeated reconciliation while a user has the history panel open.

### design_note #4
Title: AR Log Companion Pattern

When a Jira ticket is provided during import execution, the system generates a single consolidated CONSUMER_ACCOUNT_AR_LOG BDL file after all primary entity imports complete. This file creates a clerical comment (CC/CC action/result codes) on each imported record linking it back to the ticket, with the AR message referencing all entity types in the batch (e.g., "JIRA-123: PHONE, CONSUMER_TAG update via BDL Import"). This replaces the earlier per-entity AR log pattern with a single companion file per batch execution. The AR log is built from the first successful entity's staging table (identifiers are consistent across aligned entities). parent_log_ids stores a comma-separated list of all primary import log_id values the AR log covers. On the DM side, the AR log file has its own file_registry_id and processes through the BDL pipeline independently. AR log failure does not roll back primary imports.

### design_note #5
Title: DM Reconciliation Pattern

Reconciliation is driven on demand by the /api/bdl-import/history endpoint — there is no scheduled collector dedicated to this table. When the history endpoint is called, Invoke-BDLImportLogReconcile groups rows where is_complete = 0 by environment, resolves the target db_instance from Tools.EnvironmentConfig, and issues a single batched query per environment against dbo.File_Registry. This spans TEST, STAGE, and PROD — a deliberate choice to keep manual import tracking cross-environment without creating a dependency on the BatchOps BDL collector (which runs PROD-only). Frontend polling drives repeated reconciliation while a user has the page open; the GlobalConfig setting bdl_history_poll_seconds controls the poll interval. Terminal rows (is_complete = 1) are filtered out by the reconcile query itself, so load stays proportional to actively in-flight imports. Orphan handling covers the case where a lower-environment refresh removes DM-side File_Registry rows — after repeated lookup failures, the row is flagged ORPHANED and is_complete is set to 1 to stop further attempts.

### module #0

Tools

### query #1
Title: Recent import history
Description: Shows the most recent BDL imports across all environments with key details.

SELECT TOP 50 log_id, environment, entity_type, source_filename,
    row_count, validation_errors, status, error_message,
    executed_by, started_dttm, completed_dttm
FROM Tools.BDL_ImportLog
ORDER BY log_id DESC;

### query #2
Title: Failed imports requiring attention
Description: Shows failed imports that may need retry or investigation.

SELECT log_id, environment, entity_type, source_filename,
    row_count, status, error_message,
    executed_by, started_dttm
FROM Tools.BDL_ImportLog
WHERE status = 'FAILED'
ORDER BY started_dttm DESC;

### query #3
Title: Import activity by user
Description: Shows import counts and outcomes per user for auditing.

SELECT executed_by, environment, entity_type,
    COUNT(*) AS total_imports,
    SUM(CASE WHEN status = 'COMPLETED' THEN 1 ELSE 0 END) AS completed,
    SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) AS failed
FROM Tools.BDL_ImportLog
GROUP BY executed_by, environment, entity_type
ORDER BY executed_by, environment;

### query #4
Title: In-flight imports awaiting reconciliation
Description: Shows SUBMITTED imports that have not yet been reconciled to a terminal state. Useful for operational troubleshooting when the BDL Import history page shows persistent active rows.

SELECT log_id, environment, entity_type, source_filename,
    executed_by, started_dttm, last_polled_dttm,
    DATEDIFF(MINUTE, started_dttm, GETDATE()) AS minutes_since_start
FROM Tools.BDL_ImportLog
WHERE is_complete = 0
    AND status = 'SUBMITTED'
ORDER BY started_dttm DESC;

### relationship_note #1
Title: Tools.ServerConfig

Parent table. server_config_id references ServerConfig.config_id. Identifies which environment and server configuration was used for the import. The environment column is denormalized from ServerConfig for convenience.

### relationship_note #2
Title: Future Template Table

template_id is reserved for a future column mapping template table. When templates are implemented, this FK will link to the saved template used for the import. NULL indicates an ad-hoc mapping was used.

### description / column_mapping #10

JSON representation of the field mapping used for this import. Captures which source file columns were mapped to which BDL element names. Provides a complete audit trail independent of whether a template was used.

### description / completed_dttm #18

When the import reached a terminal status (COMPLETED or FAILED). Sourced from File_Registry.upsrt_dttm when reconciliation advances SUBMITTED to a terminal state. Set to GETDATE() on xFACts-side FAILED transitions. NULL while the import is in progress.

### description / created_by #31

Who created the log row.

### description / created_dttm #30

When the log row was created.

### description / entity_type #4

BDL entity type imported (e.g., PHONE, CONSUMER_TAG). Matches Catalog_BDLFormatRegistry.entity_type.

### description / environment #3

Denormalized environment from ServerConfig (PROD, STAGE, TEST). Avoids joins for common queries and history views.

### description / error_message #15

Error details captured on failure. NULL when status is not FAILED. May contain DM API error responses, validation summary, file system errors, or DM-side processing errors from File_Registry.file_err_msg_txt populated by reconciliation when DM reports a terminal failure.

### description / executed_by #16

AD username of the Control Center user who initiated the import. Captured from the authenticated session at import start.

### description / file_registry_id #19

File registry ID returned by the DM REST API after successful file registration (POST /fileregistry). NULL until the REGISTERED stage. Used as the path parameter for the import trigger call.

### description / file_registry_status #21

DM terminal status string captured by reconciliation. Values: PROCESSED, PARTIALLY_PROCESSED, FAILED, CANCELED, ORPHANED. ORPHANED is not a DM code — reconciliation sets it when File_Registry returns no row after repeated attempts, typically after a lower-environment refresh removed the DM-side record. NULL until reconciliation captures a terminal state.

### status_value / file_registry_status #1
Title: PROCESSED

DM File_Registry.file_stts_cd = 5. All records processed successfully. Paired with status = COMPLETED. Record counts: import_success_count should match total_record_count with import_failed_count = 0.

### status_value / file_registry_status #2
Title: PARTIALLY_PROCESSED

DM File_Registry.file_stts_cd = 8. Some records processed, others failed during import. Paired with status = COMPLETED. import_failed_count is non-zero; check import_success_count and import_failed_count for the split.

### status_value / file_registry_status #3
Title: FAILED

DM File_Registry.file_stts_cd = 6. Processing failed before completion. Paired with status = FAILED. error_message populated from File_Registry.file_err_msg_txt.

### status_value / file_registry_status #4
Title: CANCELED

DM File_Registry.file_stts_cd = 7. Processing was canceled. Paired with status = FAILED. Rare in practice — canceled imports typically result from manual DM-side intervention.

### status_value / file_registry_status #5
Title: ORPHANED

Not a DM code. Set by reconciliation when dbo.File_Registry returns no row for the stored file_registry_id across repeated lookup attempts. Typically occurs after a lower-environment refresh removed DM-side records, or when file_registry_id was never populated due to registration failure. is_complete is set to 1 to stop further reconciliation attempts.

### description / file_registry_status_code #20

DM File_Registry.file_stts_cd at the time of reconciliation write-back. Terminal values: 5 = PROCESSED, 6 = FAILED, 7 = CANCELED, 8 = PARTIALLY_PROCESSED. NULL until reconciliation captures a terminal state. Stored alongside file_registry_status (the string form) for operational convenience.

### description / import_failed_count #27

Records that failed during the DM import phase (post-staging). Populated by reconciliation from the Dm_import_failed_count custom detail on file_rgstry_cstm_dtl. Non-zero values combined with PARTIALLY_PROCESSED status indicate rows that staged cleanly but failed during commit to the target tables.

### description / import_processed_count #25

Total records DM attempted to import (equal to import_success_count + import_failed_count). Populated by reconciliation from the Dm_import_processed_count custom detail on file_rgstry_cstm_dtl.

### description / import_success_count #26

Records successfully imported by DM into the target entity tables. Populated by reconciliation from the Dm_import_success_count custom detail on file_rgstry_cstm_dtl. Primary indicator of import success alongside file_registry_status.

### description / is_complete #28

Completion flag driving reconciliation eligibility. 0 = active (reconciliation will attempt DM lookup on next history page load). 1 = terminal (reconciliation skips this row entirely). Set to 1 by reconciliation when DM reports any terminal file_stts_cd, when a row is flagged ORPHANED, or at xFACts-side FAILED transitions. Backed by filtered index IX_BDL_ImportLog_reconcile for efficient reconcile queries.

### description / last_polled_dttm #29

Timestamp of the most recent reconciliation attempt against DM File_Registry for this row. Updated every time the row is queried regardless of whether a terminal state was captured. Used by the history UI to display "last checked" timing and by the reconciliation helper to detect rows that have gone unresolved for extended periods.

### description / log_id #1

Identity primary key.

### description / parent_log_ids #13

Comma-separated list of primary import log_id values that this companion AR log row covers. NULL for primary imports. Populated when the execute-ar-log endpoint generates a consolidated AR log file linking back to one or more primary import rows. Replaces the former parent_log_id single FK column to support consolidated AR logs spanning multiple entity types in a single batch execution.

### description / row_count #8

Number of data rows in the uploaded file. NULL until file parsing completes. Excludes header rows.

### description / server_config_id #2

FK to Tools.ServerConfig. Identifies the environment and server configuration used for this import.

### description / source_filename #5

Original filename of the file uploaded by the user (CSV or Excel).

### description / staging_failed_count #24

Records that failed staging validation in DM. Populated by reconciliation from the Dm_staging_failed_count custom detail on file_rgstry_cstm_dtl. Non-zero values indicate data quality issues that prevented staging even though the file itself was syntactically valid.

### description / staging_success_count #23

Records successfully staged in DM during the first phase of BDL processing. Populated by reconciliation from the Dm_staging_success_count custom detail on file_rgstry_cstm_dtl.

### description / staging_table #7

Name of the Staging schema table used for this import. Correlates test-to-production imports — when the same staging table name appears on multiple rows across different environments, it indicates the user tested before promoting to production. A PROD row with a staging_table that has no corresponding TEST/STAGE row indicates a direct-to-production import.

### description / started_dttm #17

When the import process was initiated by the user.

### description / status #14

Current lifecycle status of the import. Progresses through VALIDATING, BUILDING, REGISTERED, SUBMITTED, COMPLETED, or FAILED. See status values for details.

### status_value / status #1
Title: VALIDATING

Import initiated. Uploaded file is being parsed and data validation checks are running against the column mapping.

### status_value / status #2
Title: BUILDING

Validation passed. The BDL XML file is being constructed from the mapped data.

### status_value / status #3
Title: REGISTERED

XML file written to dmfs and registered with DM via POST /fileregistry. file_registry_id is now populated.

### status_value / status #4
Title: SUBMITTED

BDL import triggered via POST /fileregistry/{id}/bdlimport. Transitional state — file handed off to DM, awaiting reconciliation to a terminal state. Reconciliation advances SUBMITTED to COMPLETED or FAILED based on File_Registry.file_stts_cd.

### status_value / status #5
Title: COMPLETED

DM reported terminal success via File_Registry.file_stts_cd (5 = PROCESSED or 8 = PARTIALLY_PROCESSED). Set by reconciliation along with file_registry_status, record counts, and completed_dttm.

### status_value / status #6
Title: FAILED

Import failed at any stage. xFACts-side validation, registration, or submission failures set this directly. Reconciliation also sets this when DM reports File_Registry.file_stts_cd 6 = FAILED or 7 = CANCELED — file_registry_status captures which. error_message contains details. A retry requires a new import with a new filename.

### description / template_id #12

FK to future template table. Identifies the saved column mapping template used for this import. NULL indicates an ad-hoc mapping was configured manually.

### description / total_record_count #22

Total record count reported by DM (file_rgstry_dtl.file_rgstry_dtl_rec_ttl_cnt). Populated by reconciliation after DM processes the file. Distinct from row_count, which captures the uploaded file's data row count at validation time.

### description / validation_errors #9

Count of rows that failed validation. 0 indicates a clean validation pass. Populated during the VALIDATING stage.

### description / value_changes #11

JSON array of value replacements applied by the user during the validation step. Each entry captures the field name, original value, replacement value, affected row count, who made the change, and when. NULL when no replacements were applied. Provides full audit trail from source file content to final import data.

### description / xml_filename #6

Name of the BDL XML file written to the dmfs import folder. NULL until the BUILDING stage completes. Used for DM file registration.

## BDL_ImportTemplate (Table)

### category #0

Operations

### data_flow #0

Templates are created from the BDL Import page Step 4 (Map Columns) via the Save Template button, which captures the current column mapping as JSON. The template list API endpoint returns all active templates for the selected entity type, displayed in the right column of the BDL Import page. When a user applies a template, the JS performs case-insensitive header matching against the current file and populates the column mapping. Templates can be updated by their creator or an admin via the slideout preview panel. Deactivation sets is_active = 0 rather than deleting the row. The template_id is referenced by BDL_ImportLog.template_id when a template-based import is executed.

### description #0

Saved column mapping templates for BDL Import. One row per template storing a reusable mapping between source file column headers and BDL element names. Templates are entity-type specific and visible to all users. The creator or an admin can update or deactivate a template. Applied templates perform case-insensitive header matching against the current file, mapping only columns that exist in both the template and the uploaded file.

### design_note #1
Title: Case-Insensitive Header Matching

When a template is applied to a new file, the mapping uses case-insensitive comparison between the template source column names and the current file headers. This accommodates vendor files where header casing may vary between exports while the column structure remains the same. Columns that exist in the template but not in the file are silently skipped — the user can manually map any remaining fields.

### design_note #2
Title: Ownership Model

Any authenticated user can create templates and all templates are visible to all users regardless of department or RBAC tier. Update and delete operations are restricted to the template creator or users with admin tier on the BDL Import page. Non-owners who want to modify a template must save a new copy under a different name.

### module #0

Tools

### relationship_note #1
Title: BDL_ImportLog

BDL_ImportLog.template_id references this table when a template-based import is executed. The template_id provides audit trail linkage between an import and the mapping template that was used. NULL template_id in the log indicates an ad-hoc mapping.

### relationship_note #2
Title: Catalog_BDLFormatRegistry

entity_type corresponds to Catalog_BDLFormatRegistry.entity_type. No physical foreign key — the entity type serves as a logical scoping filter. Templates are only presented when the user selects a matching entity type in the BDL Import wizard.

### description / column_mapping #5

JSON object storing source-to-element field mappings. Keys are source file column headers, values are BDL element names. Applied via case-insensitive header matching — only columns present in both the template and the current file are mapped.

### description / created_by #7

AD username of the user who created the template. Uses FAC\\username format from the authenticated session. Determines ownership for update and delete permissions.

### description / created_dttm #8

When the template was created.

### description / description #4

Optional user-provided description of the template. Provides context on the file layout or vendor format the template was built for.

### description / entity_type #2

BDL entity type this template applies to. Matches Catalog_BDLFormatRegistry.entity_type. Templates are scoped to a single entity type — a PHONE template cannot be used for CONSUMER_TAG imports.

### description / is_active #6

Whether this template is active. 0 = deactivated (soft delete), 1 = active (default). Deactivated templates are excluded from the template list but retained for audit.

### description / modified_by #9

Who last modified the template. NULL if never modified.

### description / modified_dttm #10

When the template was last modified. NULL if never modified.

### description / template_id #1

Identity primary key.

### description / template_name #3

User-defined name for the template. Must be unique within the entity type. Displayed in the template list and slideout preview.

## Catalog_ApiRegistry (Table)

### category #0

Catalog

### data_flow #0

Populated by a Python parsing script that reads OpenAPI 3.0 YAML specification files and generates INSERT statements. Consumed by modules that need to discover available API endpoints for automation features.

### description #0

REST API endpoint catalog containing one row per path and HTTP method combination. Parsed from OpenAPI 3.0 YAML specification files. Supports multi-product cataloging via product_name column. Links to Catalog_ApiSchemaRegistry via request_schema and response_schema for field-level detail.

### design_note #1
Title: Operation ID Not Unique

The OpenAPI spec reuses the same operationId across different paths. For example, saveImage appears on four paths (accounts, consumers, creditors, receivers). The unique constraint is on spec_version + endpoint_path + http_method, not on operation_id. Queries filtering by operation_id should expect multiple rows.

### design_note #2
Title: Operation Type Classification

The operation_type column is derived during import by pattern-matching the operationId: create/add/save/assign/import map to CREATE, retrieve/get/list/find map to RETRIEVE, update/modify map to UPDATE, delete/remove/unassign map to DELETE, search maps to SEARCH, and everything else maps to ACTION. ACTION captures non-CRUD operations like status updates, batch triggers, and workflow actions.

### design_note #3
Title: Multi-Product Design

The product_name column enables cataloging APIs from multiple products in the same table. Queries should always filter on product_name and spec_version to scope results to a specific product release.

### design_note #4
Title: Schema Linkage Pattern

The request_schema and response_schema columns contain model object names that link to Catalog_ApiSchemaRegistry.schema_name. This is a string-based link, not a foreign key, because the relationship is many-to-many (multiple endpoints share schemas) and some endpoints reference schemas that have no properties (service infrastructure types). Join on spec_version + schema_name for correct results.

### module #0

dbo

### query #1
Title: Endpoint count by resource group
Description: Overview of the API surface area showing how many endpoints exist per resource tag with CRUD breakdown.

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

### query #2
Title: Find endpoints for a resource with request/response detail
Description: Shows all endpoints for a given resource tag with their schemas. Replace the tag value as needed.

SELECT http_method, operation_id, summary, endpoint_path, 
    request_schema, response_schema, response_is_array
FROM Tools.Catalog_ApiRegistry
WHERE resource_tag = 'tags'
    AND spec_version = '11.1.0.1.6'
    AND is_deprecated = 0
ORDER BY endpoint_path, http_method;

### query #3
Title: Full endpoint detail with request body fields
Description: Joins to the schema registry to show the complete request body structure for an endpoint. Replace the operation_id as needed.

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

### relationship_note #1
Title: Catalog_ApiSchemaRegistry

Links via request_schema and response_schema to schema_name. An endpoint's request body structure is defined by the schema matching request_schema. The response structure is defined by response_schema. When response_is_array is 1, the response returns a list of that schema type. Some endpoints have NULL for both (e.g., DELETE operations with no body and 204 responses).

### description / api_version #21

FICO API version number extracted from the content type. Values 1 through 4 observed in current spec.

### description / description #9

Full description from the spec. May contain HTML markup.

### description / endpoint_id #1

Identity primary key.

### description / endpoint_path #5

URL path template with placeholders for path parameters.

### description / http_method #6

HTTP verb: GET, POST, PUT, or DELETE.

### description / is_deprecated #20

Whether the endpoint is marked deprecated in the spec.

### description / operation_id #7

OpenAPI operationId. Not guaranteed unique — some operations share the same ID across different paths.

### description / operation_type #10

Classified CRUD type derived from operationId patterns during import: CREATE, RETRIEVE, UPDATE, DELETE, SEARCH, or ACTION.

### description / path_param_count #18

Number of path parameters on this endpoint.

### description / path_params #16

Comma-separated list of path parameter names.

### description / product_name #3

Source product name. Enables future multi-product cataloging.

### description / query_param_count #19

Number of query parameters on this endpoint.

### description / query_params #17

Comma-separated list of query parameter names.

### description / request_content_type #11

Request MIME type. NULL for endpoints with no request body.

### description / request_schema #12

Schema name for the request body model object. Links to Catalog_ApiSchemaRegistry. NULL when no request body.

### description / resource_tag #4

OpenAPI tag identifying the resource group this endpoint belongs to.

### description / response_content_type #13

Response MIME type for successful responses. NULL for 204 No Content responses.

### description / response_is_array #15

Whether the successful response returns an array of the schema type.

### description / response_schema #14

Schema name for the successful response model object. Links to Catalog_ApiSchemaRegistry.

### description / spec_version #2

OpenAPI spec version identifier. No default constraint — every insert must explicitly specify.

### description / summary #8

Short one-line summary from the spec.

## Catalog_ApiSchemaRegistry (Table)

### category #0

Catalog

### data_flow #0

Populated by the same Python parsing script that populates Catalog_ApiRegistry, reading model object definitions from the components/schemas section of the OpenAPI YAML. Consumed by modules that need field-level detail for API request construction and response parsing.

### description #0

REST API schema property catalog containing one row per property within each model object. Parsed from the components/schemas section of OpenAPI 3.0 YAML specification files. Schema descriptions and property counts are denormalized onto each property row to avoid a third table. Links to Catalog_ApiRegistry via schema name.

### design_note #1
Title: Denormalized Schema Metadata

Schema-level fields (schema_description, schema_property_count) are repeated on every property row rather than stored in a separate header table. This avoids a third table while keeping queries simple. The trade-off is repeated descriptions across all property rows for a given schema — minimal storage cost.

### design_note #2
Title: Schema Cross-References

When a property is a complex type rather than a primitive, property_type is NULL and ref_schema contains the referenced schema name. When a property is an array of complex types, is_array is 1 and ref_schema contains the item schema. This enables traversing the full object graph by following ref_schema links recursively.

### design_note #3
Title: Read-Only Detection

The is_read_only flag is derived by text-matching READ-ONLY in the property description during import. This identifies system-generated fields that should not be included in POST/PUT request bodies. Not all read-only fields are explicitly marked in the spec, so this is a best-effort flag.

### module #0

dbo

### query #1
Title: Schema property detail
Description: Shows all properties for a given schema with types and descriptions. Replace schema name as needed.

SELECT property_name, property_type, ref_schema, 
    is_required, is_read_only, is_array,
    LEFT(property_description, 150) AS description_preview
FROM Tools.Catalog_ApiSchemaRegistry
WHERE schema_name = 'ConsumerAccountCaseRequestRM'
    AND spec_version = '11.1.0.1.6'
ORDER BY sort_order;

### query #2
Title: Find schemas that reference a given schema
Description: Discovers which model objects contain references to a specific schema — useful for understanding the object graph.

SELECT schema_name, property_name, is_array
FROM Tools.Catalog_ApiSchemaRegistry
WHERE ref_schema = 'ReferenceRM'
    AND spec_version = '11.1.0.1.6'
ORDER BY schema_name, sort_order;

### query #3
Title: Properties containing DM column names
Description: Many property descriptions include the underlying DM database column name in parentheses. This query finds them for cross-referencing with crs5_oltp schema.

SELECT schema_name, property_name, 
    LEFT(property_description, 200) AS description_preview
FROM Tools.Catalog_ApiSchemaRegistry
WHERE property_description LIKE '%(%_%)%'
    AND spec_version = '11.1.0.1.6'
ORDER BY schema_name, sort_order;

### relationship_note #1
Title: Catalog_ApiRegistry

Referenced by Catalog_ApiRegistry.request_schema and response_schema. Multiple endpoints may share the same schema. Join on spec_version + schema_name.

### relationship_note #2
Title: Self-referencing via ref_schema

Properties with ref_schema values reference other schemas in the same table. This creates a graph of schema relationships. For example, AREventRM has properties referencing ActionResultCodeRM, ConsumerAccountIdentifierRM, and Consumer_Contact_Log. Following these links recursively reveals the full data structure.

### description / default_value #15

Default value if specified in the spec.

### description / is_array #12

Whether this property is an array type.

### description / is_read_only #14

Whether the property description indicates READ-ONLY. Derived during import by text matching.

### description / is_required #13

Whether this property is listed in the schema required array.

### description / product_name #3

Source product name. Must match values in Catalog_ApiRegistry.

### description / property_description #10

Full property description from the spec. Often includes the underlying DM database column name in parentheses.

### description / property_format #9

OpenAPI format qualifier such as date-time or int64. NULL when not specified.

### description / property_name #7

JSON property name as it appears in API request and response payloads.

### description / property_type #8

Data type: string, integer, boolean, number, array, or object. NULL when the type is a schema reference.

### description / ref_schema #11

Referenced schema name when this property is a complex type or array of complex types. NULL for primitive types.

### description / schema_description #5

Schema-level description. Denormalized — repeated on every property row for query convenience.

### description / schema_name #4

Model object name from the OpenAPI spec. This is the join key to Catalog_ApiRegistry request_schema and response_schema columns.

### description / schema_property_count #6

Total number of properties in this schema. Denormalized — repeated on every property row.

### description / schema_property_id #1

Identity primary key.

### description / sort_order #16

Ordinal position of this property within its parent schema. 1-based.

### description / spec_version #2

OpenAPI spec version identifier. Must match values in Catalog_ApiRegistry.

## Catalog_BDLElementRegistry (Table)

### category #0

Catalog

### data_flow #0

Base structure populated by the BDL XSD parsing script. Enrichment columns (table_column, lookup_table, is_not_nullifiable, is_primary_id, field_description) populated by a separate enrichment script that parses the BDL Import/Export Interface Definition Excel workbook and matches rows to XSD elements by element name overlap scoring. Consumed by modules that perform vendor file column-mapping and BDL XML construction.

### description #0

BDL element catalog containing one row per element within each entity type. Parsed from XSD schema definition files. Element names correspond directly to DM database column names in crs5_oltp. Excludes nullify_fields structural elements. Child table of Catalog_BDLFormatRegistry via foreign key on spec_version and type_name.

### design_note #1
Title: Dual Data Sources

This table combines data from two sources: the XSD schema definitions (element_name, data_type, is_required, is_collection, max_length) and the Excel interface definition (table_column, lookup_table, is_not_nullifiable, is_primary_id, field_description). XSD data covers all elements. Excel enrichment covers the data entity fields but not wrapper/container references.

### design_note #2
Title: XSD Required vs Import Required

The is_required column reflects XSD minOccurs and is almost always 0 (false) — the XSD is permissive by design. The is_not_nullifiable column from the Excel reflects practical import requirements: fields that must have values for the import to succeed, or that cannot be cleared via nullify_fields. These are the fields that matter for building import files.

### design_note #3
Title: Collection Elements

Elements with is_collection = 1 are child entity references in wrapper/container types. Their data_type values are BDL complexType names (e.g., bdl_cnsmr_phn_data_type) rather than primitive types. These elements define the BDL XML hierarchy — which entities can appear within each operational transaction. Query them to discover valid entity nesting.

### design_note #4
Title: Table Column vs Element Name

The table_column enrichment column is only populated when the DM database column name differs from the BDL XML element name. When NULL, the element_name is the column name. Common differences include reference code fields where the XML uses a _val_txt suffix but the database column uses a _cd suffix.

### module #0

dbo

### query #1
Title: Entity fields with enrichment data
Description: Shows all elements for a BDL entity including Excel enrichment. Replace entity_type value as needed.

SELECT e.element_name, e.data_type, e.is_required, e.max_length,
    e.table_column, e.lookup_table, e.is_not_nullifiable, e.is_primary_id,
    LEFT(e.field_description, 120) AS description_preview
FROM Tools.Catalog_BDLElementRegistry e
INNER JOIN Tools.Catalog_BDLFormatRegistry f
    ON e.spec_version = f.spec_version AND e.type_name = f.type_name
WHERE f.entity_type = 'PHONE'
    AND f.spec_version = '11.1.0.1.6'
ORDER BY e.sort_order;

### query #2
Title: Required fields for BDL import
Description: Shows fields that are practically required for import (not-nullifiable or primary IDs). This is the foundation for the column-mapping UI validation.

SELECT f.entity_type, e.element_name, e.is_not_nullifiable, e.is_primary_id,
    e.lookup_table, LEFT(e.field_description, 100) AS description_preview
FROM Tools.Catalog_BDLElementRegistry e
INNER JOIN Tools.Catalog_BDLFormatRegistry f
    ON e.spec_version = f.spec_version AND e.type_name = f.type_name
WHERE (e.is_not_nullifiable = 1 OR e.is_primary_id = 1)
    AND f.spec_version = '11.1.0.1.6'
ORDER BY f.entity_type, e.sort_order;

### query #3
Title: Fields with lookup table references
Description: Shows elements that reference DM lookup tables for valid values. Useful for building validation dropdowns in the import UI.

SELECT f.entity_type, e.element_name, e.lookup_table,
    LEFT(e.field_description, 100) AS description_preview
FROM Tools.Catalog_BDLElementRegistry e
INNER JOIN Tools.Catalog_BDLFormatRegistry f
    ON e.spec_version = f.spec_version AND e.type_name = f.type_name
WHERE e.lookup_table IS NOT NULL
    AND f.spec_version = '11.1.0.1.6'
ORDER BY f.entity_type, e.sort_order;

### query #4
Title: Discover BDL XML structure for an entity
Description: Shows the full path from operational transaction wrapper to data entity, then lists the entity fields. This is the query pattern for constructing BDL import XML.

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

### relationship_note #1
Title: Catalog_BDLFormatRegistry

Child table. Each element belongs to exactly one format entity via foreign key on spec_version + type_name.

### description / data_type #7

Data type with xs: prefix stripped. Primitive types: string, long, decimal, dateTime, int, short, boolean, date. Non-primitive values reference other BDL complexType names for container/child entity relationships.

### description / display_name #6

Human-readable field name for display in the column mapping UI. Shown alongside or in place of the technical element_name to help users identify fields without needing to know DM column names. NULL values fall back to element_name display.

### description / element_id #1

Identity primary key.

### description / element_name #5

XSD element name. For data entities, corresponds to the DM database column name. For container types, references child entity type names.

### description / field_description #18

Human-readable field description from the Excel interface definition. Supplements the XSD structural data with business context.

### description / format_id #2

FK to Catalog_BDLFormatRegistry.format_id. Integer-based link to the parent entity type, replacing the composite (spec_version, type_name) join. The spec_version and type_name columns are retained as informational context.

### description / import_guidance #19

Operational guidance text displayed during BDL import to help users fill in the field correctly. Examples: "Required numeric value — enter 0 if not in source data" for phone quality score, "Optional — defaults to current timestamp if blank" for tag assignment date. Separate from field_description which documents what the field is. NULL when no special import guidance is needed.

### description / is_collection #9

Whether the element has maxOccurs="unbounded", indicating it is a child entity reference that can appear multiple times in the XML. Primarily found on container types in bdl_import_export.xsd.

### description / is_conditional_eligible #17

Identifies fields eligible for conditional value assignment during BDL Import. When set to 1, the FIXED_VALUE mapping UI offers a Conditional mode where this field's value can vary per row based on a trigger column from the uploaded file, rather than being applied as a blanket fixed value to all rows. Fields with 0 (default) use the standard blanket assignment only. Currently set on tag_shrt_nm for CONSUMER_TAG and ACCOUNT_TAG entities.

### description / is_import_required #16

Whether this element must be mapped for a BDL import to succeed. 0 = optional (default), 1 = required. Reflects practical DM import requirements as determined by operational experience, distinct from is_required (XSD structural minimum) and is_not_nullifiable (cannot be cleared on update). Populated based on team review of each entity type.

### description / is_not_nullifiable #13

Whether this element cannot be included in nullify_fields during BDL update operations. Sourced from the Excel Not Nullifiable Columns sheets. Elements marked not-nullifiable are typically identifiers or required business fields.

### description / is_primary_id #14

Whether this element is a system-generated primary key identifier. These are auto-assigned by DM and not user-supplied during import. Sourced from the Excel Not Nullifiable Columns Primary ID column.

### description / is_required #8

Whether the element is required per XSD minOccurs. Note: XSD requirements are structural minimums — practical import requirements are determined by DM business logic and may differ.

### description / is_visible #15

Whether this element is shown to users in the BDL Import column mapping UI. 1 = visible (default), 0 = hidden. System-generated fields, unreliable identifiers, and internal DM fields should be hidden to prevent user errors. Does not affect the catalog's completeness — hidden elements remain in the spec but are excluded from the import picker.

### description / lookup_table #12

Reference table containing valid values for this element. From the Excel interface definition Look Up Table column.

### description / max_length #10

Maximum string length from XSD maxLength restriction. NULL for non-string types or when no restriction is specified.

### description / sort_order #20

Ordinal position of this element within its parent entity. 1-based.

### description / spec_version #3

XSD spec version identifier. Foreign key to Catalog_BDLFormatRegistry.

### description / table_column #11

DM database column name from the Excel interface definition. NULL when not enriched or when the table column matches the element name. Only populated when the names differ.

### description / type_name #4

Parent entity complexType name. Foreign key to Catalog_BDLFormatRegistry.

## Catalog_BDLFormatRegistry (Table)

### category #0

Catalog

### data_flow #0

Populated by a Python parsing script that reads BDL XSD schema definition files from DM release packages. Each row represents a BDL data entity that can be imported via bulk data load. Consumed by modules that perform BDL import automation — vendor file upload, column mapping, and XML construction.

### description #0

BDL bulk data load format catalog containing one row per entity type. Parsed from XSD schema definition files. Each entity type represents a DM data entity that can be imported via BDL. Parent table for Catalog_BDLElementRegistry.

### design_note #1
Title: Folder Column as Hierarchy Indicator

The folder column captures the subdirectory path within the BDL XSD folder (consumer, consumer/account, payment/settlement, etc.). This provides an at-a-glance view of the entity hierarchy without needing to parse the wrapper types in bdl_import_export.xsd.

### design_note #2
Title: Wrapper and Container Types

The format registry includes wrapper types from bdl_import_export.xsd (e.g., consumer_operational_transaction_data_type, account_operational_transaction_data_type) that have NULL entity_type. These define which data entities belong to each BDL operational transaction. Their child elements in the element registry have is_collection = 1 and data_type values referencing the actual data entity type names.

### design_note #3
Title: Nullify Fields Support

Entities with has_nullify_fields = 1 support the BDL nullification mechanism — a way to explicitly clear field values during update operations. The nullify_fields structural element itself is excluded from the element registry since it is not a data element.

### design_note #4
Title: Batch ID Construction

The BDL XML batch_id_txt header element maps to DM file_rgstry_dtl.btch_idntfr_txt, which is VARCHAR(32). Build-BDLXml constructs this value as XF_{batch_abbreviation}_{yyyyMMddHHmmss}, using the batch_abbreviation column to keep the total within the 32-character limit. If batch_abbreviation is NULL, the entity_type is truncated to 14 characters as a fallback.

### module #0

dbo

### query #1
Title: All BDL data entities
Description: Lists importable BDL entity types excluding wrapper/container types.

SELECT entity_type, type_name, folder, element_count, has_parent_ref, has_nullify_fields
FROM Tools.Catalog_BDLFormatRegistry
WHERE spec_version = '11.1.0.1.6'
    AND entity_type IS NOT NULL
ORDER BY folder, entity_type;

### query #2
Title: BDL operational transaction structure
Description: Shows which data entities belong to each operational transaction type by querying the wrapper container elements.

SELECT f.type_name AS container, e.element_name AS entity_ref, e.data_type AS entity_type_name
FROM Tools.Catalog_BDLFormatRegistry f
INNER JOIN Tools.Catalog_BDLElementRegistry e
    ON f.spec_version = e.spec_version AND f.type_name = e.type_name
WHERE f.entity_type IS NULL
    AND f.folder IS NULL
    AND e.is_collection = 1
    AND f.spec_version = '11.1.0.1.6'
ORDER BY f.type_name, e.sort_order;

### relationship_note #1
Title: Catalog_BDLElementRegistry

Parent table. Each format has zero or more elements in Catalog_BDLElementRegistry linked by foreign key on spec_version + type_name.

### description / action_type #11

Controls which mapping UI is rendered for each entity type in the BDL Import wizard. FILE_MAPPED uses column-to-field drag-and-drop mapping panels. FIXED_VALUE presents direct value entry fields where the user enters uniform values applied to all rows (used for tagging operations). HYBRID is reserved for future entities requiring a mix of both approaches. CHECK constraint enforces valid values. Defaults to FILE_MAPPED.

### status_value / action_type #1
Title: FILE_MAPPED

Default. User maps source file columns to BDL fields via drag-and-drop panels. Used for entity types where field values come from the uploaded file.

### status_value / action_type #2
Title: FIXED_VALUE

User enters values directly rather than mapping from file columns. The identifier comes from the file, but payload values are entered by the user and applied uniformly to every row. Used for tagging operations.

### status_value / action_type #3
Title: HYBRID

Reserved for future use. Combination of file-mapped and manually entered fields.

### description / batch_abbreviation #13

Short abbreviation used in the BDL XML batch_id_txt header element. The batch_id_txt value is constructed as XF_{abbreviation}_{yyyyMMddHHmmss} and must not exceed 32 characters, which is the column limit on the DM file_rgstry_dtl.btch_idntfr_txt column. Maximum 14 characters. Editable through the admin catalog modal. Falls back to a truncated entity_type if NULL.

### description / element_count #7

Number of data elements defined in this entity type. Excludes the nullify_fields structural element.

### description / entity_key #12

Identifies which DM identifier field drives the import for this entity type. CONSUMER entities use cnsmr_idntfr_agncy_id as the key. ACCOUNT entities use cnsmr_accnt_idntfr_agncy_id. OTHER covers specialized entities that do not fit either pattern. Used by the BDL Import wizard to group entity type cards into visual sections on the selection screen. NULL for wrapper and deferred entity types not yet classified.

### status_value / entity_key #1
Title: CONSUMER

Entity uses cnsmr_idntfr_agncy_id as the import key. Displayed in the Consumer section of the entity selection grid.

### status_value / entity_key #2
Title: ACCOUNT

Entity uses cnsmr_accnt_idntfr_agncy_id as the import key. Displayed in the Account section of the entity selection grid.

### status_value / entity_key #3
Title: OTHER

Specialized entity that does not fit the consumer or account key pattern. Displayed in the Other section of the entity selection grid.

### description / entity_type #3

Entity type name from the XSD fixed type attribute. NULL for wrapper, container, and utility types defined in bdl_import_export.xsd.

### description / folder #6

Subdirectory path within the BDL XSD folder. Indicates the entity hierarchy: consumer, consumer/account, payment/settlement, etc. NULL for root-level files.

### description / format_id #1

Identity primary key.

### description / has_nullify_fields #9

Whether this entity supports field nullification via the nullify_fields element. A BDL-specific feature for clearing field values on update.

### description / has_parent_ref #8

Whether this entity has a bdl_parent_id attribute indicating a parent-child relationship.

### description / is_active #10

Whether this entity type is active and available for use. 1 = active (default), 0 = deactivated. Deactivated entities do not appear in entity selection for any user including admin. Deactivation cascades naturally through query filtering — AccessConfig and AccessFieldConfig rows referencing a deactivated entity become unreachable without requiring updates to those tables.

### description / operational_transaction_type #14

The operational_transaction_type value emitted in the operational_transaction_type element of the BDL XML header for this entity type. The XML builder reads this value directly from the catalog.

### description / spec_version #2

XSD spec version identifier. No default constraint — every insert must explicitly specify.

### description / type_name #4

XSD complexType name. This is the join key to Catalog_BDLElementRegistry.

### description / xsd_filename #5

Source XSD filename.

## Catalog_CDLElementRegistry (Table)

### category #0

Catalog

### data_flow #0

Populated alongside Catalog_CDLFormatRegistry by the CDL XSD parsing script. Element names correspond directly to DM database column names in crs5_oltp. Consumed by modules that need to discover available fields for CDL import/export operations.

### description #0

CDL element catalog containing one row per element within each entity type. Parsed from XSD schema definition files. Element names correspond directly to DM database column names in crs5_oltp. Child table of Catalog_CDLFormatRegistry via foreign key on spec_version and type_name.

### design_note #1
Title: Element Names Are Column Names

CDL element names map directly to crs5_oltp database column names. This is a key difference from BDL, where element names sometimes differ from table column names. CDL elements can be used directly for cross-referencing with the DM OLTP schema.

### module #0

dbo

### query #1
Title: Entity fields with types
Description: Shows all elements for a given CDL entity type. Replace entity_type value as needed.

SELECT e.element_name, e.data_type, e.is_required, e.max_length
FROM Tools.Catalog_CDLElementRegistry e
INNER JOIN Tools.Catalog_CDLFormatRegistry f
    ON e.spec_version = f.spec_version AND e.type_name = f.type_name
WHERE f.entity_type = 'CREDITOR'
    AND f.spec_version = '11.1.0.1.6'
ORDER BY e.sort_order;

### relationship_note #1
Title: Catalog_CDLFormatRegistry

Child table. Each element belongs to exactly one format entity via foreign key on spec_version + type_name.

### description / data_type #7

XSD data type with xs: prefix stripped. Common values: string, boolean, int, long, decimal, dateTime, short.

### description / display_name #6

Human-readable field name for display in the column mapping UI. Shown alongside or in place of the technical element_name to help users identify fields without needing to know DM column names. NULL values fall back to element_name display.

### description / element_id #1

Identity primary key.

### description / element_name #5

XSD element name. Corresponds to the DM database column name.

### description / format_id #2

FK to Catalog_CDLFormatRegistry.format_id. Integer-based link to the parent entity type, replacing the composite (spec_version, type_name) join. The spec_version and type_name columns are retained as informational context.

### description / is_import_required #10

Whether this element must be mapped for a CDL import to succeed. 0 = optional (default), 1 = required. Mirrors the Catalog_BDLElementRegistry pattern for consistency across catalog tables.

### description / is_required #8

Whether the element is required per XSD minOccurs. Derived from minOccurs: 0 means optional, 1 or unspecified means required.

### description / is_visible #9

Whether this element is shown to users in import/export UIs. 1 = visible (default), 0 = hidden. Mirrors the Catalog_BDLElementRegistry pattern for consistency across catalog tables.

### description / max_length #11

Maximum string length from XSD maxLength restriction. NULL for non-string types or when no restriction is specified.

### description / sort_order #12

Ordinal position of this element within its parent entity. 1-based.

### description / spec_version #3

XSD spec version identifier. Foreign key to Catalog_CDLFormatRegistry.

### description / type_name #4

Parent entity complexType name. Foreign key to Catalog_CDLFormatRegistry.

## Catalog_CDLFormatRegistry (Table)

### category #0

Catalog

### data_flow #0

Populated by a Python parsing script that reads CDL XSD schema definition files from DM release packages. Each row represents a CDL configuration entity type that can be imported or exported. Consumed by modules that perform CDL import/export automation and configuration management.

### description #0

CDL configuration data format catalog containing one row per entity type. Parsed from XSD schema definition files. Each entity type represents a DM configuration object that can be imported or exported via CDL. Parent table for Catalog_CDLElementRegistry.

### design_note #1
Title: Entity Types vs Sub-Types

Most entities have an entity_type value from the XSD fixed type attribute (e.g., CREDITOR, ACTIONCODE). Some entries have NULL entity_type — these are sub-types, utility types, or abstract base types defined in shared XSD files like cdl_udp_field_type.xsd. The type_name column is always populated and serves as the primary identifier.

### design_note #2
Title: Parent-Child Relationships

Entities with has_parent_ref = 1 have a cdl_item_stgng_prnt_id attribute in the XSD, indicating they are child entities that reference a parent during import. For example, CREDITOR_CONFIGURATION is a child of CREDITOR. The parent relationship is not explicitly stored in this table — it is implied by the CDL import structure and documented in the DM interface definition.

### module #0

dbo

### query #1
Title: All CDL entity types
Description: Lists all CDL configuration entity types with their element counts and parent reference status.

SELECT entity_type, type_name, element_count, has_parent_ref, xsd_filename
FROM Tools.Catalog_CDLFormatRegistry
WHERE spec_version = '11.1.0.1.6'
    AND entity_type IS NOT NULL
ORDER BY entity_type;

### relationship_note #1
Title: Catalog_CDLElementRegistry

Parent table. Each format has zero or more elements in Catalog_CDLElementRegistry linked by foreign key on spec_version + type_name.

### description / element_count #6

Number of data elements defined in this entity type.

### description / entity_type #3

Entity type name from the XSD fixed type attribute. NULL for sub-types and utility types that lack a type attribute.

### description / format_id #1

Identity primary key.

### description / has_parent_ref #7

Whether this entity has a cdl_item_stgng_prnt_id attribute indicating a parent-child relationship.

### description / is_active #8

Whether this entity type is active and available for use. 1 = active (default), 0 = deactivated. Deactivated entities do not appear in entity selection for any user including admin.

### description / spec_version #2

XSD spec version identifier. No default constraint — every insert must explicitly specify.

### description / type_name #4

XSD complexType name. This is the join key to Catalog_CDLElementRegistry.

### description / xsd_filename #5

Source XSD filename within the CDL entity folder.

## EnvironmentConfig (Table)

### category #0

Operations

### data_flow #0

Rows are manually inserted when a new DM environment is configured. The BDL Import workflow reads this table to resolve the dmfs file path and database instance based on the user's environment selection. API URLs are resolved separately from dbo.ServerRegistry using the environment value. Future Tools pipelines (Payment, CDL, New Business) consume the same rows using their respective folder columns.

### description #0
Description: Per-environment configuration for Tools module operations. One row per DM environment (PROD, STAGE, TEST), providing crs5_oltp database instance and dmfs file import paths. API URLs are sourced from dbo.ServerRegistry.

Per-server configuration for Tools module operations. One row per tools-enabled target server, providing DM API connection details and dmfs file import paths. Child of dbo.ServerRegistry via server_id foreign key.

### design_note #2
Title: Path Construction Pattern

Full file paths are constructed by combining dmfs_base_path with the pipeline-specific folder column and a trailing backslash. For example, a BDL import path is dmfs_base_path + backslash + dmfs_bdl_folder + backslash. The folder columns have sensible defaults but are stored explicitly so paths remain configurable without code changes.

### module #0

Tools

### query #1
Title: Configuration by environment
Description: Returns the full server configuration for a given environment. Primary query pattern for all Tools operations.

SELECT environment, db_instance, dmfs_base_path,
    dmfs_bdl_folder, dmfs_cdl_folder,
    dmfs_payment_folder, dmfs_newbusiness_folder
FROM Tools.EnvironmentConfig
WHERE environment = 'PROD'
    AND is_active = 1;

### description / config_id #1

Identity primary key.

### description / created_by #14

Who created the configuration.

### description / created_dttm #13

When the configuration was created.

### description / db_instance #5

SQL Server instance name or AG listener for the crs5_oltp database in this environment. Used by validation and query operations that need to read DM reference tables. For standalone environments (TEST), this is the same as server_name. For AG environments (PROD, STAGE), this is the AG listener name.

### description / dmfs_base_path #7

Base UNC path for the DM file system import folder (e.g., \\\\dm-prod-app3\\e$\\dmfs\\import). Pipeline-specific subfolder columns are appended to construct full paths.

### description / dmfs_bdl_folder #8

Subfolder name under dmfs_base_path for BDL import files. Default: bdl.

### description / dmfs_cdl_folder #9

Subfolder name under dmfs_base_path for CDL import files. Default: cdl.

### description / dmfs_newbusiness_folder #11

Subfolder name under dmfs_base_path for new business import files. Default: newbusiness.

### description / dmfs_payment_folder #10

Subfolder name under dmfs_base_path for payment import files. Default: payments.

### description / environment #4
Description: Environment identifier (PROD, STAGE, TEST). Used as the primary lookup key when the UI environment selector resolves to a configuration. Also used to join to dbo.ServerRegistry for API URL resolution.

Denormalized environment from ServerRegistry (PROD, STAGE, TEST). Used as the primary lookup key when the UI environment selector resolves to a server configuration.

### description / is_active #12

Whether this server configuration is active. 0 = disabled, 1 = enabled (default).

### description / modified_by #16

Who last modified the configuration.

### description / modified_dttm #15

When the configuration was last modified.

## parse-css.js (Script)

### category #0

Utilities

### description #0

Node.js helper script invoked as a subprocess from PowerShell to parse CSS source files into structured JSON. Wraps PostCSS 8.5.12 and postcss-selector-parser 7.1.1 for AST extraction with full line-number metadata and decomposed selector trees. Output drives the CSS extraction populator in the Asset_Registry parser pipeline.

### module #0

Tools

## parse-js.js (Script)

### category #0

Utilities

### description #0

Node.js helper script invoked as a subprocess from PowerShell to parse JavaScript source files into structured JSON. Wraps Acorn 8.16.0 and acorn-walk 8.3.5 for AST extraction with full source position metadata. Output drives the JS extraction populator in the Asset_Registry parser pipeline.

### module #0

Tools

## Populate-AssetRegistry-CSS.ps1 (Script)

### category #0

Utilities

### description #0

Asset_Registry parser pipeline component for CSS source files. Walks every CSS file in the Control Center codebase, parses each via the parse-css.js Node helper, and emits one Asset_Registry row per cataloged construct. Validates each row against CC_CSS_Spec.md rules and attaches drift codes for any deviation.

### module #0

Tools

## Populate-AssetRegistry-HTML.ps1 (Script)

### category #0

Utilities

### description #0

Asset_Registry parser pipeline component for HTML markup embedded in PowerShell files. Walks every .ps1 and .psm1 file under the Control Center route and helper directories, identifies HTML-emitting constructs, and emits one Asset_Registry row per cataloged HTML construct. Validates each row against CC_HTML_Spec.md rules and attaches drift codes for any deviation.

### module #0

Tools

## Populate-AssetRegistry-JS.ps1 (Script)

### category #0

Utilities

### description #0

Asset_Registry parser pipeline component for JavaScript source files. Walks every JS file in the Control Center codebase, parses each via the parse-js.js Node helper, and emits Asset_Registry rows for both JS code constructs and HTML markup found inside template strings. Validates each row against CC_JS_Spec.md rules and attaches drift codes for any deviation.

### module #0

Tools

## Populate-AssetRegistry-PS.ps1 (Script)

### category #0

Utilities

### description #0

Asset_Registry parser pipeline component for PowerShell source files. Walks every .ps1 and .psm1 file under the xFACts PowerShell roots, parses each via the native PowerShell AST, and emits one Asset_Registry row per cataloged construct. Validates each row against CC_PS_Spec.md rules and attaches drift codes for any deviation.

### module #0

Tools

## Resolve-AssetRegistryReferences.ps1 (Script)

### category #0

Utilities

### description #0

Cross-spec resolution phase of the Asset_Registry pipeline. Runs after the four populators have written DEFINITION and USAGE rows. Resolves every cross-spec USAGE row's source_file and scope against matching DEFINITION rows; emits edge-specific drift codes when references cannot be resolved, and a catch-all UNRESOLVED_REFERENCE code on any row that remains in the <pending> state after the resolve phase completes.

### module #0

Tools

## sp_SyncColumnOrdinals (Procedure)

### category #0

Utilities

### description #0

Aligns Object_Metadata column description sort_order values with actual sys.columns column_id ordinals. Compares active column description rows against the system catalog, updates misaligned sort_order values to match current column positions, and deactivates description rows for columns that no longer exist. Supports three scopes: single table (both parameters provided), all tables in a schema (@SchemaName only), or full database (no parameters). Returns a detail result set in single-table preview mode and a per-table summary in all other modes. Runs in preview mode by default.

### design_note #1
Title: Preview-First Safety
Description: Default behavior prevents accidental changes.

@PreviewOnly defaults to 1, requiring an explicit opt-in to apply changes. The preview output shows every proposed action (UPDATE or DEACTIVATE) with before and after sort_order values, plus a summary of aligned, misaligned, orphaned, and missing columns. This makes it safe to run exploratively against any table without risk.

### design_note #2
Title: Orphan Handling
Description: Detects and deactivates metadata for dropped columns.

When a column exists in Object_Metadata but not in sys.columns, the row is deactivated (is_active = 0) and sort_order is set to 0 rather than deleted. This preserves the documentation history while removing the orphan from active exports and reference pages.

### design_note #3
Title: Missing Column Detection
Description: Reports columns that lack documentation but does not create rows.

Columns found in sys.columns with no matching active Object_Metadata description row are reported in the output as informational. The proc does not auto-generate description rows — that remains a manual enrichment task to ensure content quality.

### module #0

Tools

### relationship_note #1
Title: Object_Metadata

Reads and updates dbo.Object_Metadata rows where property_type is description and column_name is populated. Only active rows (is_active = 1) are evaluated. Sort_order updates and deactivations set modified_dttm and modified_by via GETDATE() and SUSER_SNAME().

### description / @ObjectName #2

Table name without schema qualifier. Requires @SchemaName when provided. When both are specified, targets that single table and returns a detail result set in preview mode. NULL (default) enables schema-wide or database-wide processing.

### description / @PreviewOnly #3

Controls execution mode. 1 (default) displays a comparison report without making changes. 0 applies sort_order updates and deactivates orphaned rows. Always run in preview mode first to review proposed changes.

### description / @SchemaName #1

Schema name to scope the sync operation. When provided with @ObjectName, targets a single table. When provided alone, processes all tables in that schema with active column descriptions. When NULL (default), all schemas are processed.

## xFACts-AssetRegistryFunctions.ps1 (Script)

### category #0

Utilities

### data_flow #0

Reads dbo.Object_Registry to build the (file_name to registry_id) map used at bulk-insert time for foreign-key resolution. Reads dbo.Component_Registry joined to dbo.Object_Registry to build the (file_name to cc_prefix) map used by populators for prefix registry validation. Writes to dbo.Asset_Registry via SqlBulkCopy from a DataTable assembled from per-populator row collections. All reads and writes use the configured xFACts database connection inherited from xFACts-OrchestratorFunctions.ps1.

### description #0

Shared function library for the Asset_Registry parser pipeline. Dot-sourced by every populator in the family after xFACts-OrchestratorFunctions.ps1. Centralizes row construction, drift code attachment, occurrence-index computation, registry loads, bulk insert, banner detection and parsing, file-header parsing, pre-built section list construction, and the generic AST visitor walker.

### design_note #1
Title: Hybrid Drift Code Attachment

Add-DriftCode validates each code against a per-populator master $script:DriftDescriptions hashtable; unknown codes are refused with a warning. Description text defaults to the master entry but can be overridden per-call with a -Context string for row-specific detail (e.g., a function name that fails its prefix check). Test-DriftCodesAgainstMasterTable runs at the output boundary before bulk insert as a final guardrail against typos and stale codes that escaped validation.

### design_note #2
Title: Pre-Built Section List with Body-Line Ranges

New-SectionList walks every block comment in a parsed file once at the start of per-file processing, identifies banner-shaped comments via Test-IsBannerComment, parses each via Get-BannerInfo, and produces a sorted list of section instances with body-line ranges (banner-end+1 to next-banner-start-1). Get-SectionForLine then provides O(n) line-to-section lookup during AST walking. Replaces the legacy running-state model that depended on walker-equals-source-order traversal — the pre-built list is correct under any walking order, including tree-order visitor walks where nodes at higher line numbers may be visited before nodes at lower line numbers.

### module #0

Tools

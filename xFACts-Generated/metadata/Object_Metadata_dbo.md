# Object_Metadata: dbo
Source: dbo.Object_Metadata
Generated: 2026-07-24 05:27:08

## ActionAuditLog (Table)

### category #0  [metadata_id: 1670]

Shared Infrastructure

### data_flow #0  [metadata_id: 2110]

Populated by Control Center API route handlers whenever a user performs an action through any CC page. Each discrete action generates one row with a human-readable summary. Rows are append-only and never updated or deleted.

### description #0  [metadata_id: 123]

Centralized audit trail for all user-initiated actions in the Control Center. Captures configuration changes, schedule edits, job triggers, BDL imports, access grants, alert resends, and any other operational action performed through the UI.

### design_note #1  [metadata_id: 2111]
Title: Action Summary Pattern

Each row captures a single user action with a human-readable action_summary string built by the calling code. The summary includes all relevant context (e.g., "Changed orchestrator_drain_mode from 0 to 1" or "Triggered Refresh Drools (3 servers)"). This avoids structured old/new value columns in favor of flexibility across diverse action types.

### design_note #2  [metadata_id: 2112]
Title: Cooldown Enforcement

Operational actions with cooldown periods (e.g., Balance Sync at 60 minutes) query the most recent successful execution by action_type, action_summary pattern, and environment to determine eligibility. The table serves as both audit trail and throttle source.

### module #0  [metadata_id: 1566]

dbo

### query #1  [metadata_id: 2115]
Title: Recent actions across all pages
Description: Shows the most recent user actions with full context.

SELECT TOP 50 page_route, action_type, action_summary,
       environment, result, error_detail,
       executed_by, executed_dttm
FROM dbo.ActionAuditLog
ORDER BY executed_dttm DESC;

### query #2  [metadata_id: 2116]
Title: Actions by type
Description: Filtered audit history for a specific action category.

SELECT action_summary, environment, result, error_detail,
       executed_by, executed_dttm
FROM dbo.ActionAuditLog
WHERE action_type = 'JOB_TRIGGER'
ORDER BY executed_dttm DESC;

### query #3  [metadata_id: 2117]
Title: Cooldown check for job triggers
Description: Finds the most recent successful execution of a specific trigger in an environment.

SELECT TOP 1 executed_dttm
FROM dbo.ActionAuditLog
WHERE action_type = 'JOB_TRIGGER'
  AND action_summary LIKE '%Balance Sync%'
  AND environment = 'PROD'
  AND result = 'SUCCESS'
ORDER BY executed_dttm DESC;

### relationship_note #1  [metadata_id: 2118]
Title: GlobalConfig

CONFIG_CHANGE entries originating from GlobalConfig edits on the Admin page. Action summary includes the setting name and old/new values.

### description / action_summary #4  [metadata_id: 4188]

Human-readable description of what happened, built by the calling code to capture essential context in a single string.

### description / action_type #3  [metadata_id: 4187]

Action category: CONFIG_CHANGE, SCHEDULE_CHANGE, JOB_TRIGGER, BDL_IMPORT, ACCESS_CHANGE, ALERT_RESEND.

### status_value / action_type #1  [metadata_id: 2113]
Title: CONFIG_CHANGE

A configuration setting was modified through a Control Center administrative interface.

### status_value / action_type #2  [metadata_id: 2114]
Title: JOB_TRIGGER

A DM scheduled job or process was manually triggered through the Control Center.

### description / audit_id #1  [metadata_id: 4185]

Primary key identity.

### description / environment #5  [metadata_id: 4189]

Target DM environment for environment-scoped actions (TEST, STAGE, PROD). NULL for actions that are not environment-specific.

### description / error_detail #7  [metadata_id: 4191]

Error message captured on failure. NULL on success or for action types where result is not tracked.

### description / executed_by #8  [metadata_id: 4192]

AD username of the user who performed the action (FAC\ domain prefix).

### description / executed_dttm #9  [metadata_id: 4193]

Timestamp when the action was performed.

### description / page_route #2  [metadata_id: 4186]

Control Center page route where the action originated (e.g., /admin, /bdl-import, /apps-int).

### description / result #6  [metadata_id: 4190]

Outcome for operational actions: SUCCESS or FAILED. NULL for instant actions like config changes.

## API_RequestLog (Table)

### category #0  [metadata_id: 1671]

Shared Infrastructure

### data_flow #0  [metadata_id: 2119]

Populated automatically by Pode middleware in the Control Center on every API request completion. Each row captures the endpoint, HTTP method, caller identity, response timing, and status code. The logging middleware is designed to fail silently rather than impact actual API requests. Request and response bodies are intentionally excluded to avoid storage bloat and sensitivity concerns.

### description #0  [metadata_id: 41]

Tracks API request metrics for volume and performance analysis. Initially captures Control Center API traffic with extensibility for future API sources.

### design_note #1  [metadata_id: 2120]
Title: Source Application Extensibility

The source_application column (currently 'ControlCenter' for all rows) allows future expansion to log API traffic from multiple applications in a single table for unified analysis.

### design_note #2  [metadata_id: 2121]
Title: Silent Failure Design

The logging middleware catches all exceptions internally and never throws. Logging failures must not impact the actual API request being processed. Observability should never cause the problem it's trying to detect.

### module #0  [metadata_id: 1567]

dbo

### query #1  [metadata_id: 2122]
Title: Request volume by endpoint (last 24 hours)
Description: Shows traffic patterns and performance per endpoint.

SELECT endpoint, COUNT(*) AS request_count,
       AVG(duration_ms) AS avg_duration_ms,
       MAX(duration_ms) AS max_duration_ms
FROM dbo.API_RequestLog
WHERE request_dttm >= DATEADD(HOUR, -24, GETDATE())
GROUP BY endpoint
ORDER BY request_count DESC;

### query #2  [metadata_id: 2123]
Title: Slowest endpoints (last 24 hours)
Description: Identifies performance bottlenecks by average response time.

SELECT endpoint, COUNT(*) AS request_count,
       AVG(duration_ms) AS avg_duration_ms,
       MAX(duration_ms) AS max_duration_ms
FROM dbo.API_RequestLog
WHERE request_dttm >= DATEADD(DAY, -1, GETDATE())
GROUP BY endpoint
ORDER BY avg_duration_ms DESC;

### description / client_ip #5  [metadata_id: 254]

Client IP address (supports IPv6)

### description / duration_ms #8  [metadata_id: 257]

Total processing time in milliseconds

### description / endpoint #2  [metadata_id: 251]

The API path called (e.g., /api/backup/pipeline-status)

### description / http_method #3  [metadata_id: 252]

HTTP method (GET, POST, PUT, DELETE)

### description / request_dttm #7  [metadata_id: 256]

When the request was processed

### description / request_id #1  [metadata_id: 250]

Unique identifier for the log entry

### description / response_bytes #10  [metadata_id: 259]

Size of response body in bytes

### description / source_application #11  [metadata_id: 260]

Application that logged the request (e.g., ControlCenter)

### description / status_code #9  [metadata_id: 258]

HTTP response status code (200, 404, 500, etc.)

### description / user_agent #6  [metadata_id: 255]

User-Agent header - identifies browser, script, or application

### description / user_name #4  [metadata_id: 253]

Authenticated user name from AD

## Asset_Registry (Table)

### category #0  [metadata_id: 4976]

Shared Infrastructure

### description #0  [metadata_id: 4974]

Catalog of every component (CSS class, JS function, HTML ID, API route, etc.) extracted from Control Center source files. One row per definition or usage instance. Distinguishes local from shared scope and maps consumption to definition. Serves as both descriptive catalog (what exists, where) and prescriptive reference (naming conventions, established patterns). Populated by parser scripts that walk all CC source files, parse them via language-appropriate AST tools (PostCSS for CSS, Acorn for JS, built-in PowerShell parser for .ps1/.psm1), and produce one row per extracted component instance. Refresh strategy is truncate-and-reload per file_type, reflecting current state only with no historical retention.

### module #0  [metadata_id: 4975]

Engine

### description / asset_id #1  [metadata_id: 5037]

Surrogate primary key. Not stable across runs.

### description / body_hash #21  [metadata_id: 5115]

Exact fingerprint of a definition's body, SHA-256 as 64 hex characters. Computed from the construct body with language-specific scaffolding removed (for functions: the declaration line, parameter block, binding/output attributes, and documentation block), remaining tokens rendered verbatim. Two rows sharing body_hash are byte-identical bodies (true copy-paste). Set on the promotable DEFINITION rows each populator chooses to fingerprint (constructs that could become shared resources, such as functions); NULL on rows where a body fingerprint does not apply.

### description / column_start #8  [metadata_id: 5043]

The 0-based column where this construct begins on its starting line.

### description / component_name #10  [metadata_id: 5045]

The construct's identifier.

### description / component_type #9  [metadata_id: 5044]

The type of construct this row represents.

### description / drift_codes #27  [metadata_id: 5058]

Comma-separated list of spec-drift codes attached to this row.

### description / drift_text #28  [metadata_id: 5059]

Pipe-separated human-readable descriptions corresponding to drift_codes.

### description / file_name #2  [metadata_id: 5038]

The source file the row was extracted from.

### description / file_type #4  [metadata_id: 5040]

The content type extracted, not the file extension.

### description / has_dynamic_content #22  [metadata_id: 5073]

When TRUE, the parent attribute or text construct from which this row was extracted also contains runtime-only content the populator cannot statically resolve (e.g., a class attribute that combines literal class names with a parameter-passed class name). When FALSE or NULL, the parent construct is fully captured in the catalog. Used by HTML and JS populator rows; not meaningful for CSS rows, which are always fully literal.

### description / last_parsed_dttm #30  [metadata_id: 5060]

Timestamp of the run that inserted this row.

### description / line_end #7  [metadata_id: 5042]

The 1-based source line where this construct ends.

### description / line_start #6  [metadata_id: 5041]

The 1-based source line where this construct begins.

### description / match_reference #29  [metadata_id: 5140]

The name(s) the populator's matching criteria resolved to for this row -- a token, function, export, dispatch handler, action key, or other named construct the row was matched or resolved against. Records positive findings only, not rejected or weighed candidates; NULL when the criteria resolved to no match. Comma-space delimited when more than one match resolves. This column reports what the populator found; the drift_codes column independently reports whether that finding, or its absence, constitutes drift.

### description / object_registry_id #3  [metadata_id: 5039]

Foreign key to dbo.Object_Registry.registry_id. NULL when the file has no Object_Registry row.

### description / occurrence_index #26  [metadata_id: 5057]

1-based ordinal disambiguator for repeated instances within a file.

### description / parent_function #23  [metadata_id: 5054]

The enclosing context, where applicable.

### description / purpose_description #25  [metadata_id: 5056]

Human-authored description of the construct, extracted from preceding comments.

### description / raw_text #24  [metadata_id: 5055]

Verbatim source text of the construct.

### description / reference_type #14  [metadata_id: 5049]

Whether this row defines a construct or references one.

### description / scope #15  [metadata_id: 5050]

Whether the construct lives in a curated shared file or in a page-local file.

### description / shape_hash #20  [metadata_id: 5116]

Structural fingerprint of a definition's body, SHA-256 as 64 hex characters. Same normalization as body_hash but with string and numeric literals folded to placeholder tokens and identifier references folded to a single token, while called-name and member-access names are kept literal. Two rows sharing shape_hash are the same logic differing only in literals, identifier names, casing, or formatting (combinable with little or no change). Set on the promotable DEFINITION rows each populator chooses to fingerprint; NULL where it does not apply.

### description / signature #18  [metadata_id: 5053]

Construct-specific structural detail.

### description / skeleton_hash #19  [metadata_id: 5117]

Maximally loose family fingerprint of a definition's body, SHA-256 as 64 hex characters. Computed from the set of structural construct types present (for functions: control-flow constructs, returns, throws, and aggregate-builder forms), independent of their order, count, the names called, identifiers, and literals. Intended as a name-free entry point: rows sharing skeleton_hash form a loose candidate family that is then narrowed by shape_hash, body_hash, signature, and name. Deliberately coarse - common skeletons return large generic cohorts by design, and skeleton_hash is never used in isolation to make consolidation determinations. Set on the promotable DEFINITION rows each populator chooses to fingerprint; NULL where it does not apply.

### description / source_file #16  [metadata_id: 5051]

For DEFINITION rows, equals file_name. For USAGE rows, the file where the construct is defined.

### description / source_section #17  [metadata_id: 5052]

The full title of the section banner this row belongs to.

### description / variant_qualifier_1 #12  [metadata_id: 5047]

First qualifier slot of the variant.

### description / variant_qualifier_2 #13  [metadata_id: 5048]

Second qualifier slot of the variant.

### description / variant_type #11  [metadata_id: 5046]

Discriminates sub-flavors within a component_type.

### description / zone #5  [metadata_id: 5087]

Partition identifier separating the Control Center catalog from the Documentation site catalog. Every USAGE row resolves only against DEFINITION rows in the same zone; cross-zone resolution does not occur. Valid values: 'cc' (Control Center application files) and 'docs' (Documentation site files). Written by every populator at row emission time based on the file path being scanned.

## ClientHierarchy (Table)

### category #0  [metadata_id: 4214]

Shared Infrastructure

### data_flow #0  [metadata_id: 4226]

Sync-ClientHierarchy.ps1 rebuilds the entire table daily via MERGE, reading from crs5_oltp.dbo.crdtr and crs5_oltp.dbo.crdtr_grp on the AG. The recursive CTE resolves the full creditor group hierarchy in a single pass. The B2B module uses this table to resolve Integration CREDITOR_NAME values (CE/CB codes) to the DM client hierarchy for crosswalk and grouping operations.

### description #0  [metadata_id: 4212]

Complete flattened DM creditor hierarchy providing single-lookup resolution from any creditor to its direct parent group and ultimate top-level parent. Rebuilt daily by Sync-ClientHierarchy.ps1 using a recursive CTE against crs5_oltp creditor and creditor group tables. Standalone creditors (crdtr_grp_id = 1) self-reference — their parent and top parent fields point to themselves. Includes all creditors regardless of transaction history or active status.

### design_note #1  [metadata_id: 4227]
Title: Standalone Creditor Self-Reference

Creditors assigned to crdtr_grp_id = 1 (the internal default group) are standalone — they have no meaningful group membership. Rather than NULLing the parent and top parent columns, these creditors self-reference: their parent_group and top_parent fields point back to their own creditor_id, creditor_key, and creditor_name. This avoids NULL handling in every consumer query and allows consistent GROUP BY top_parent_name behavior.

### design_note #2  [metadata_id: 4228]
Title: Group 1 Exclusion

The CTE anchor excludes crdtr_grp_id = 1 (DefGrp / Internal Creditor Group) to prevent duplicate path resolution. Group 1 is a system default, not a real parent. Including it would create false hierarchy paths for creditors that happen to be in the default group.

### design_note #3  [metadata_id: 4229]
Title: Full Population vs Activity-Filtered

This table includes ALL creditors regardless of transaction history or recency. This differs from the legacy Jira_ClientTblRanked table which filters to 13 months of activity. Full population ensures the crosswalk works for any creditor the B2B system references, even inactive or dormant ones.

### module #0  [metadata_id: 4213]

dbo

### relationship_note #1  [metadata_id: 4230]
Title: Sync-ClientHierarchy.ps1

Rebuild script that performs the full MERGE. Reads crs5_oltp.dbo.crdtr and crs5_oltp.dbo.crdtr_grp via the AG listener. Registered in ProcessRegistry for daily execution.

### relationship_note #2  [metadata_id: 4231]
Title: B2B.ProcessConfig

The B2B module will use ClientHierarchy to resolve Integration CREDITOR_NAME (CE/CB codes) from CLIENTS_ACCTS to the full DM hierarchy for client grouping and display.

### description / creditor_id #1  [metadata_id: 4215]

DM creditor identifier (crdtr_id from crs5_oltp.dbo.crdtr). Primary key.

### description / creditor_key #2  [metadata_id: 4216]

DM creditor short name (crdtr_shrt_nm) — the CE/CB code used as the crosswalk key to B2B CREDITOR_NAME.

### description / creditor_name #3  [metadata_id: 4217]

DM creditor display name (crdtr_nm).

### description / is_active #10  [metadata_id: 4224]

Creditor active status derived from crdtr_stts_cd = 1 in crs5_oltp.

### description / last_refreshed_dttm #13  [metadata_id: 4225]

Timestamp of the most recent sync cycle that wrote or confirmed this row.

### description / parent_group_id #4  [metadata_id: 4218]

Direct parent creditor group identifier. Self-references creditor_id for standalone creditors (crdtr_grp_id = 1).

### description / parent_group_is_active #11  [metadata_id: 4232]

Direct parent group active status derived from crdtr_grp_sft_dlt_flg in crs5_oltp (N = active, Y = soft-deleted). For standalone creditors (self-referencing), mirrors the creditor is_active flag. Enables detection of active creditors assigned to inactive groups.

### description / parent_group_key #5  [metadata_id: 4219]

Direct parent group short name. Self-references creditor_key for standalone creditors.

### description / parent_group_name #6  [metadata_id: 4220]

Direct parent group display name. Self-references creditor_name for standalone creditors.

### description / top_parent_id #7  [metadata_id: 4221]

Highest ancestor creditor group identifier resolved via recursive CTE. Self-references creditor_id for standalone creditors.

### description / top_parent_is_active #12  [metadata_id: 4233]

Top-level parent group active status derived from crdtr_grp_sft_dlt_flg at the highest ancestor level. For standalone creditors (self-referencing), mirrors the creditor is_active flag. Combined with parent_group_is_active and is_active, enables full hierarchy health assessment.

### description / top_parent_key #8  [metadata_id: 4222]

Highest ancestor group short name. Self-references creditor_key for standalone creditors.

### description / top_parent_name #9  [metadata_id: 4223]

Highest ancestor group display name. Self-references creditor_name for standalone creditors.

## Component_Registry (Table)

### category #0  [metadata_id: 3121]

Shared Infrastructure

### data_flow #0  [metadata_id: 3129]

Rows are inserted when new components are defined during platform development. Referenced by Object_Registry (FK on component_name) and System_Metadata (FK on component_name). The Admin page System Metadata modal reads Component_Registry to display the component tree and allow version bumps. New components can be added via the Admin UI. The doc_* columns drive the documentation pipeline — a JSON export (doc-registry.json) is generated from rows where doc_page_id is populated and consumed by the site navigation, Hub card grid, and documentation publisher.

### description #0  [metadata_id: 3119]

Catalog of logical components in the xFACts platform. Each component groups related database objects, scripts, and Control Center files into a single versioned unit. Component_Registry defines what groupings exist; Object_Registry holds the individual object membership; System_Metadata tracks version history against these components.

### design_note #1  [metadata_id: 3130]
Title: Component naming convention
Description: How component_name values are structured.

Components use dot notation when a module has multiple components (ServerOps.Backup, ServerOps.Index, ControlCenter.Admin). Module-level components where the module has only one component use the plain module name (JobFlow, Teams, BatchOps). This provides natural grouping in sorted displays while keeping names concise.

### design_note #2  [metadata_id: 3131]
Title: Three-table versioning model
Description: How Component_Registry, Object_Registry, and System_Metadata work together.

Component_Registry defines the logical groupings. Object_Registry catalogs every individual object and links it to its parent component. System_Metadata tracks version history per component. The component_name column is the natural join key across all three tables. A component exists because it has a row here; its contents are in Object_Registry; its version history is in System_Metadata.

### design_note #3  [metadata_id: 3345]
Title: Documentation single source of truth

The doc_* columns consolidate three previously independent page registries into a single database-driven source. A JSON export (doc-registry.json) is generated by the documentation pipeline and consumed by the site navigation, the Hub card grid, and the documentation publisher. Adding a new documentation page requires only populating the doc_* columns on the component row and re-running the pipeline — no code changes needed.

### design_note #4  [metadata_id: 3346]
Title: Convention-based page discovery

Filenames are derived from doc_page_id by convention with standard suffixes. Child page existence is determined by filesystem check — if the file exists in the expected directory, the nav renders the link. New page types can be added by establishing a suffix convention without any schema changes.

### design_note #5  [metadata_id: 3347]
Title: Multi-component pages

Multiple components can share the same doc_page_id when they contribute sections to the same page. One component is the primary row (has doc_sort_order and doc_title populated). Additional components are secondary rows with only doc_page_id, doc_json_schema, doc_json_categories, and doc_section_order populated. The reference page groups and orders sections by doc_section_order.

### design_note #6  [metadata_id: 3352]
Title: Index page identification
Description: Sort order convention replaces dedicated flag column.

The documentation site index page is identified by doc_sort_order = 0. All module pages use increments of 10 starting at 10. This convention eliminates the need for a separate boolean column and is enforced by the documentation pipeline consumers (nav.js, publisher, JSON export). Only one row should have sort order 0.

### design_note #7  [metadata_id: 3377]
Title: Named CC Guide Pages

The standard documentation convention is one CC guide page per pageId ({pageId}-cc.html). When a pageId needs multiple CC guide pages — because its Control Center presence spans multiple distinct pages with different functionality — the doc_cc_slug column enables named pages ({pageId}-cc-{slug}.html). The presence of any non-NULL slug for a pageId suppresses the standard single-file check in nav.js, preventing a confusing mix of generic and named links. Slug rows must also have doc_title populated for nav labels, and doc_page_id set to the parent pageId.

### module #0  [metadata_id: 3120]

dbo

### query #1  [metadata_id: 3182]
Title: All active components by module
Description: Lists all registered components grouped by module.

SELECT module_name, component_name, description
FROM dbo.Component_Registry
WHERE is_active = 1
ORDER BY module_name, component_name;

### query #2  [metadata_id: 3183]
Title: Components with their object counts by category
Description: Shows each component with a breakdown of how many objects it contains per category.

SELECT
    cr.component_name,
    SUM(CASE WHEN oreg.object_category = 'Database' THEN 1 ELSE 0 END) AS db_objects,
    SUM(CASE WHEN oreg.object_category = 'PowerShell' THEN 1 ELSE 0 END) AS ps_scripts,
    SUM(CASE WHEN oreg.object_category = 'WebAsset' THEN 1 ELSE 0 END) AS web_assets,
    SUM(CASE WHEN oreg.object_category = 'Documentation' THEN 1 ELSE 0 END) AS doc_files,
    COUNT(oreg.registry_id) AS total
FROM dbo.Component_Registry cr
LEFT JOIN dbo.Object_Registry oreg
    ON oreg.component_name = cr.component_name AND oreg.is_active = 1
WHERE cr.is_active = 1
GROUP BY cr.component_name
ORDER BY cr.component_name;

### relationship_note #1  [metadata_id: 3132]
Title: Object_Registry

Object_Registry has a foreign key to Component_Registry on component_name. Every object in the platform is linked to exactly one component through this relationship.

### relationship_note #2  [metadata_id: 3133]
Title: System_Metadata

System_Metadata has a foreign key to Component_Registry on component_name. Version history entries are recorded against the component, not individual objects.

### description / cc_prefix #5  [metadata_id: 5036]

Three-character lowercase page prefix used by CC pages to scope local CSS class names and JS top-level identifiers. NULL for shared and infrastructure components with no CC page. Source of truth for the Prefix Registry consumed by the CSS and JS asset populators during file-header validation.

### description / component_id #1  [metadata_id: 3122]

Auto-incrementing primary key.

### description / component_name #3  [metadata_id: 3124]

Unique component identifier using dot notation for scoped components (e.g., ServerOps.Backup, ControlCenter.Admin) or plain name for module-level components (e.g., JobFlow, Teams).

### description / created_by #15  [metadata_id: 3128]

Who registered this component. Auto-populated via SUSER_SNAME() default.

### description / created_dttm #14  [metadata_id: 3127]

When this component was registered. Auto-populated via default.

### description / description #4  [metadata_id: 3125]

Brief description of what this component encompasses — the functional scope and purpose.

### description / doc_cc_slug #11  [metadata_id: 3376]

Named CC guide page slug. When populated, this component has a dedicated CC guide page at {pageId}-cc-{slug}.html in the cc/ subfolder. The doc_title on this same row provides the nav label. When NULL, the standard single-file convention {pageId}-cc.html applies. Only activates when at least one section row for the pageId has a slug — backward compatible with all existing single-CC-guide pages.

### description / doc_json_categories #10  [metadata_id: 3340]

Category filter(s) applied when the component uses only a subset of a schema's objects on the reference page. Comma-separated. Filters the JSON data by the category field in Object_Metadata. NULL when no filtering is needed or no reference page contribution exists.

### description / doc_json_schema #9  [metadata_id: 3339]

Schema name(s) for the JSON DDL reference data consumed by the reference page. Comma-separated when multiple schemas contribute. Maps to JSON filenames in the documentation data directory. NULL when the component does not contribute objects to a reference page.

### description / doc_page_id #7  [metadata_id: 3337]

Unique page identifier used by the documentation pipeline to derive filenames, build navigation, and link consumers to pages. NULL for components without documentation pages. Multiple components can share the same doc_page_id when they contribute sections to the same page.

### description / doc_section_order #13  [metadata_id: 3342]

Display order for this component's section within a multi-component reference page. Controls the sequence of schema sections in the reference page navigation. For single-component pages, this is 1. NULL for the Hub and components without documentation pages.

### description / doc_sort_order #12  [metadata_id: 3341]

Display order for page position in navigation and the index card grid. Lower values appear first. Uses increments of 10 for easy insertion of new pages. A value of 0 identifies the index page (site root). Only populated on the primary row for each page. NULL for secondary rows and components without documentation pages.

### description / doc_title #8  [metadata_id: 3338]

Display title for the page — used in site navigation, Hub card grid, and published documentation. Only populated on the primary row for each page (the row with doc_sort_order set). NULL for secondary rows on multi-component pages and for components without documentation pages.

### description / is_active #6  [metadata_id: 3126]

Soft delete flag. 1 = active component, 0 = retired/decommissioned.

### status_value / is_active #1  [metadata_id: 3134]
Title: 1

Component is active and in use. Default value on INSERT.

### status_value / is_active #2  [metadata_id: 3135]
Title: 0

Component has been retired or decommissioned. Objects may still exist in Object_Registry for historical reference.

### description / module_name #2  [metadata_id: 3123]

Functional module this component belongs to: dbo, ServerOps, JobFlow, BatchOps, BIDATA, FileOps, Teams, Jira, Orchestrator, ControlCenter, DeptOps.

## Credentials (Table)

### category #0  [metadata_id: 1672]

Shared Infrastructure

### data_flow #0  [metadata_id: 2089]

Rows are manually inserted with encrypted VARBINARY values using application-layer encryption with a two-tier passphrase model (master passphrase decrypts a service-specific passphrase, which decrypts individual credential values). PowerShell scripts query at runtime to retrieve API tokens, usernames, and passwords for external service integrations (Jira, Teams, SFTP) without hardcoding sensitive data. Decryption occurs in the consuming script, not at the database level.

### description #0  [metadata_id: 47]

Secure credential storage table containing encrypted configuration values for external service authentication. Used by PowerShell scripts and procedures to retrieve API keys, tokens, and connection strings without hardcoding sensitive data.

### design_note #1  [metadata_id: 2090]
Title: Two-Tier Encryption Model

Credentials use ENCRYPTBYPASSPHRASE with a two-tier key hierarchy: a master passphrase decrypts a service-specific passphrase stored as a ConfigKey = 'Passphrase' row, which in turn decrypts the actual credential values (Username, Password, ApiToken). This provides key rotation at the service level without re-encrypting all credentials.

### design_note #2  [metadata_id: 2091]
Title: Composite Primary Key with Environment

The three-column composite key (Environment, ServiceName, ConfigKey) allows the same service to have different credentials for DEV, TEST, and PROD environments in a single table. Scripts filter by Environment = 'PROD' at query time.

### module #0  [metadata_id: 1568]

dbo

### relationship_note #1  [metadata_id: 2092]
Title: CredentialServices

Child table. ServiceName references CredentialServices.ServiceName. CredentialServices defines the catalog of valid services; Credentials stores the actual encrypted values per environment.

### relationship_note #2  [metadata_id: 2093]
Title: FileOps.ServerConfig

FileOps.ServerConfig.credential_service_name references the same ServiceName values, linking SFTP server configurations to their authentication credentials.

### description / ConfigKey #3  [metadata_id: 306]

Specific credential key (e.g., ApiToken, Username, Password)

### description / ConfigValue #4  [metadata_id: 3654]

Encrypted credential value stored as VARBINARY. Decrypted at runtime by consuming PowerShell scripts using the two-tier passphrase model. Contains API keys, tokens, passwords, or connection strings depending on the ConfigKey.

### description / CreatedDate #5  [metadata_id: 307]

When the credential was created

### description / Environment #1  [metadata_id: 304]

Environment identifier (DEV, TEST, PROD)

### description / ModifiedDate #6  [metadata_id: 308]

When the credential was last updated

### description / ServiceName #2  [metadata_id: 305]

Service this credential belongs to (FK to CredentialServices)

## CredentialServices (Table)

### category #0  [metadata_id: 1673]

Shared Infrastructure

### data_flow #0  [metadata_id: 2094]

Rows are manually inserted when a new external service integration is established. Serves as the parent lookup table for Credentials, enforcing valid ServiceName values through referential integrity. The ServiceType column categorizes integrations for reporting (API, Webhook, Database, FileShare, Email).

### description #0  [metadata_id: 44]

Reference table defining external services that require stored credentials. Provides metadata about each service type and serves as the parent lookup for the Credentials table.

### design_note #1  [metadata_id: 2095]
Title: Service Catalog Purpose

This table centralizes the list of all external integrations in one place, making it easy to understand the platform's integration footprint. Deactivating a service here (Is_Active = 0) does not automatically prevent credential retrieval but signals that the integration should not be used.

### module #0  [metadata_id: 1569]

dbo

### relationship_note #1  [metadata_id: 2101]
Title: Credentials

Parent table. Credentials.ServiceName references CredentialServices.ServiceName. Each service can have multiple credential rows (one per Environment + ConfigKey combination).

### description / Created_Date #5  [metadata_id: 275]

When the service was registered

### description / Description #3  [metadata_id: 273]

Human-readable description of the service purpose

### description / Is_Active #4  [metadata_id: 274]

Whether credentials for this service should be used

### description / ServiceName #1  [metadata_id: 272]

Unique identifier for the service (e.g., JiraAPI, TeamsWebhook)

### description / ServiceType #2  [metadata_id: 3655]

Category of external integration. Classifies services for reporting and grouping: API, Webhook, Database, FileShare, Email.

### status_value / ServiceType #1  [metadata_id: 2096]
Title: API

REST or SOAP API integration (e.g., JiraAPI, ServiceNow).

### status_value / ServiceType #2  [metadata_id: 2097]
Title: Webhook

Outbound webhook notification targets (e.g., TeamsWebhook).

### status_value / ServiceType #3  [metadata_id: 2098]
Title: Database

External database connections (e.g., LinkedServer, Oracle).

### status_value / ServiceType #4  [metadata_id: 2099]
Title: FileShare

Network file share or SFTP access (e.g., SFTPServer).

### status_value / ServiceType #5  [metadata_id: 2100]
Title: Email

Email service credentials (e.g., SMTPRelay, Office365).

## DatabaseRegistry (Table)

### category #0  [metadata_id: 1674]

Shared Infrastructure

### data_flow #0  [metadata_id: 2083]

Rows are manually inserted when enrolling a database for xFACts operations. The server_id foreign key links to ServerRegistry. Monitoring scripts query this table joined to ServerRegistry to determine which databases to process. Module-specific configuration tables (e.g., ServerOps.DatabaseConfig) link via database_id for component settings like backup, index maintenance, and statistics preferences.

### description #0  [metadata_id: 79]

Registry of databases enrolled in xFACts operations, linking databases to their host servers. This is a shared infrastructure table providing database identification for all modules.

### design_note #1  [metadata_id: 2084]
Title: Identity Only Design

This table contains only identification and server linkage. Component-specific settings live in dedicated configuration tables (ServerOps.DatabaseConfig, etc.), keeping the shared registry focused on identity. This separation was created when the original ServerOps.DatabaseRegistry was split during the dbo schema refactoring.

### design_note #2  [metadata_id: 2085]
Title: Explicit Enrollment

Databases must be explicitly enrolled rather than auto-discovered. This prevents accidental operations on vendor databases or systems not ready for automated management.

### module #0  [metadata_id: 1570]

dbo

### query #1  [metadata_id: 2086]
Title: All enrolled databases with server info
Description: Shows all active database enrollments joined to their host server.

SELECT d.database_id, d.database_name, s.server_name, s.environment,
       d.is_active, d.notes
FROM dbo.DatabaseRegistry d
JOIN dbo.ServerRegistry s ON s.server_id = d.server_id
WHERE d.is_active = 1
ORDER BY s.server_name, d.database_name;

### relationship_note #1  [metadata_id: 2087]
Title: ServerRegistry

Child table. server_id references ServerRegistry.server_id. Each database belongs to exactly one server.

### relationship_note #2  [metadata_id: 2088]
Title: ServerOps.DatabaseConfig

One-to-one extension. ServerOps.DatabaseConfig.database_id references DatabaseRegistry.database_id for component-specific settings (backup, index, statistics configuration).

### description / created_by #6  [metadata_id: 845]

Who created the enrollment

### description / created_dttm #5  [metadata_id: 844]

When the enrollment was created

### description / database_id #1  [metadata_id: 840]

Unique identifier for the database enrollment

### description / database_name #3  [metadata_id: 842]

Database name as it appears in sys.databases

### description / is_active #4  [metadata_id: 843]

Whether this enrollment is active

### description / modified_by #8  [metadata_id: 847]

Who last modified the enrollment

### description / modified_dttm #7  [metadata_id: 846]

When the enrollment was last modified

### description / server_id #2  [metadata_id: 841]

FK to ServerRegistry.server_id

## GlobalConfig (Table)

### category #0  [metadata_id: 1675]

Shared Infrastructure

### data_flow #0  [metadata_id: 2044]

Rows are manually inserted or updated when configuring module behavior. Every PowerShell monitoring script and the Control Center read settings at startup or per-cycle using module_name and setting_name lookups. The Control Center GlobalConfig editor page provides a UI for modifying values, with every change logged to dbo.ActionAuditLog as entity_type = 'GlobalConfig'. The is_ui_editable flag controls which settings appear in the editor.

### description #0  [metadata_id: 85]

Consolidated key-value configuration table for all xFACts modules. Stores settings that control component behavior, thresholds, paths, and operational parameters.

### design_note #1  [metadata_id: 2045]
Title: Consolidation from Module-Specific Tables

GlobalConfig replaced four separate configuration tables (ServerOps.Activity_Config, Backup_Config, Disk_Config, Maintenance_Config) during the dbo schema refactoring. The consolidated design provides a single query pattern across all modules while module_name and category maintain logical separation.

### design_note #2  [metadata_id: 2046]
Title: String Storage with Type Hint

All values are stored as VARCHAR in setting_value with a data_type column (INT, DECIMAL, BIT, VARCHAR) indicating how to interpret the value. Consuming code is responsible for casting. This avoids multiple typed columns while preserving type intent for the Control Center editor.

### design_note #3  [metadata_id: 2047]
Title: UI Editability Control

The is_ui_editable flag determines which settings appear in the Control Center GlobalConfig editor. Settings that should only be changed with direct database access (e.g., structural configuration) can be hidden from the UI while remaining queryable by scripts.

### module #0  [metadata_id: 1571]

dbo

### query #1  [metadata_id: 2048]
Title: All settings for a module
Description: Shows all active configuration for a specific module with category grouping.

SELECT setting_name, setting_value, data_type, category, description
FROM dbo.GlobalConfig
WHERE module_name = 'ServerOps'
  AND is_active = 1
ORDER BY category, setting_name;

### query #2  [metadata_id: 2049]
Title: Search for a setting by keyword
Description: Finds settings across all modules matching a keyword pattern.

SELECT module_name, category, setting_name, setting_value, description
FROM dbo.GlobalConfig
WHERE setting_name LIKE '%threshold%'
  AND is_active = 1
ORDER BY module_name, setting_name;

### query #3  [metadata_id: 2050]
Title: UI-editable settings
Description: Shows settings available for editing in the Control Center.

SELECT module_name, category, setting_name, setting_value, data_type, description
FROM dbo.GlobalConfig
WHERE is_ui_editable = 1
  AND is_active = 1
ORDER BY module_name, category, setting_name;

### relationship_note #1  [metadata_id: 2051]
Title: ActionAuditLog

Every Control Center edit to a GlobalConfig setting generates an ActionAuditLog row with entity_type = 'GlobalConfig' and entity_name = the setting_name, capturing old_value and new_value for audit trail.

### relationship_note #2  [metadata_id: 2052]
Title: ProcessRegistry

The orchestrator engine reads heartbeat_interval_seconds and orchestrator_drain_mode from GlobalConfig on every cycle. Multiple module scripts read their own settings at startup.

### description / category #6  [metadata_id: 920]

Component within module (Index, Backup, Activity_XE, Activity_DMV, Disk)

### description / config_id #1  [metadata_id: 915]

Unique identifier for the setting

### description / created_by #12  [metadata_id: 926]

Who created the setting

### description / created_dttm #11  [metadata_id: 925]

When the setting was created

### description / data_type #5  [metadata_id: 919]

How to interpret the value: INT, DECIMAL, BIT, VARCHAR

### description / description #8  [metadata_id: 922]

What this setting controls

### description / is_active #7  [metadata_id: 921]

Whether this setting is currently in effect

### description / is_ui_editable #9  [metadata_id: 923]

Determines whether config is available for editing in Control Center UI

### description / module_name #2  [metadata_id: 916]

Module that owns this setting (ServerOps, dbo, JobFlow, etc.)

### description / notes #10  [metadata_id: 924]

Additional context or reason for current value

### description / setting_name #3  [metadata_id: 917]

Setting identifier (must be unique within module)

### description / setting_value #4  [metadata_id: 918]

The configuration value (stored as string)

## Holiday (Table)

### category #0  [metadata_id: 1676]

Shared Infrastructure

### data_flow #0  [metadata_id: 2102]

Populated via sp_GenerateHolidays for standard annual US holidays (fixed and floating) or sp_AddHoliday for individual company-specific entries. Both procedures apply weekend observation rules (Saturday to Friday, Sunday to Monday). Scheduling-aware modules query this table to determine if the current date is a holiday. Currently consumed by the ServerOps Index component via ServerOps.HolidaySchedule for maintenance window determination.

### description #0  [metadata_id: 60]

Calendar of company holiday dates used by scheduling components across xFACts modules. Contains the list of recognized holidays; actual schedule behaviors are defined in module-specific tables.

### design_note #1  [metadata_id: 2103]
Title: Date as Primary Key

The holiday_date column is the primary key. Each calendar date can appear at most once, preventing duplicate entries. This means the observed date is stored, not the actual holiday date when they differ due to weekend observation.

### design_note #2  [metadata_id: 2104]
Title: Calendar Only — No Schedule Behavior

This table contains only the holiday calendar. How each module behaves on holidays is defined in module-specific tables (e.g., ServerOps.HolidaySchedule). This separation allows different modules to react differently to the same holiday.

### module #0  [metadata_id: 1572]

dbo

### query #1  [metadata_id: 2105]
Title: Upcoming holidays
Description: Shows the next 12 months of active holidays.

SELECT holiday_date, DATENAME(WEEKDAY, holiday_date) AS day_of_week, holiday_name
FROM dbo.Holiday
WHERE holiday_date BETWEEN GETDATE() AND DATEADD(YEAR, 1, GETDATE())
  AND is_active = 1
ORDER BY holiday_date;

### query #2  [metadata_id: 2106]
Title: Check if today is a holiday
Description: Quick check used by scheduling logic.

SELECT holiday_name
FROM dbo.Holiday
WHERE holiday_date = CAST(GETDATE() AS DATE)
  AND is_active = 1;

### relationship_note #1  [metadata_id: 2107]
Title: sp_GenerateHolidays

Bulk population procedure that calculates and inserts standard US holidays for a given year, including floating holidays (Memorial Day, Thanksgiving) and weekend observation shifts.

### relationship_note #2  [metadata_id: 2108]
Title: sp_AddHoliday

Single-holiday insertion procedure for company-specific holidays or one-off closures not covered by the annual generation.

### relationship_note #3  [metadata_id: 2109]
Title: ServerOps.HolidaySchedule

Defines per-database maintenance window behavior on holidays. References Holiday dates to determine whether index maintenance should run, and with what time window, on each holiday.

### description / created_by #5  [metadata_id: 526]

Who added this holiday

### description / created_dttm #4  [metadata_id: 525]

When this holiday was added

### description / holiday_date #1  [metadata_id: 522]

Calendar date of the holiday (use observed date for weekend holidays)

### description / holiday_name #2  [metadata_id: 523]

Display name (e.g., "Christmas Day", "Thanksgiving", "Memorial Day")

### description / is_active #3  [metadata_id: 524]

Whether this holiday is currently recognized for scheduling purposes

## Module_Registry (Table)

### category #0  [metadata_id: 3190]

Shared Infrastructure

### data_flow #0  [metadata_id: 3197]

Rows are inserted when new functional modules are established. Referenced by Component_Registry, Object_Registry, and System_Metadata via FK on module_name. The Admin page System Metadata modal reads Module_Registry to display module taglines on the tree header rows.

### description #0  [metadata_id: 3188]

Top-level module definitions for the xFACts platform. Each module represents a functional domain (ServerOps, JobFlow, Teams, etc.). Completes the three-tier hierarchy: Module_Registry ? Component_Registry ? Object_Registry. The description column holds a brief business-friendly tagline displayed in the Control Center admin panel.

### design_note #1  [metadata_id: 3198]
Title: Three-tier hierarchy
Description: Completes the Module ? Component ? Object model.

Module_Registry defines the top-level functional domains. Component_Registry groups related objects within a module. Object_Registry catalogs individual assets. System_Metadata tracks version history at the component level. module_name is the natural join key across all four tables.

### design_note #2  [metadata_id: 3199]
Title: Tagline brevity constraint
Description: Why the description column is VARCHAR(100).

The description is displayed inline on the module header row in the admin panel, filling the visual gap between the module name and the component/object counts. Longer descriptions would wrap or truncate. The 8-words-or-less guideline keeps taglines scannable at a glance.

### module #0  [metadata_id: 3189]

dbo

### query #1  [metadata_id: 3205]
Title: All active modules
Description: Lists all registered modules with their taglines.

SELECT module_name, description
FROM dbo.Module_Registry
WHERE is_active = 1
ORDER BY module_name;

### relationship_note #1  [metadata_id: 3200]
Title: Component_Registry

Component_Registry has a foreign key to Module_Registry on module_name. Every component must belong to a registered module.

### relationship_note #2  [metadata_id: 3201]
Title: Object_Registry

Object_Registry has a foreign key to Module_Registry on module_name. Provides direct module lookup without joining through Component_Registry.

### relationship_note #3  [metadata_id: 3202]
Title: System_Metadata

System_Metadata has a foreign key to Module_Registry on module_name. Version entries reference the module for grouping in the admin tree.

### description / created_by #6  [metadata_id: 3196]

Who registered this module. Auto-populated via SUSER_SNAME() default.

### description / created_dttm #5  [metadata_id: 3195]

When this module was registered. Auto-populated via default.

### description / description #3  [metadata_id: 3193]

Business-friendly tagline, 8 words or less. Displayed on the module header row in the System Metadata admin panel.

### description / is_active #4  [metadata_id: 3194]

Soft delete flag. 1 = active module, 0 = retired.

### status_value / is_active #1  [metadata_id: 3203]
Title: 1

Module is active. Default value on INSERT.

### status_value / is_active #2  [metadata_id: 3204]
Title: 0

Module has been retired or decommissioned.

### description / module_id #1  [metadata_id: 3191]

Auto-incrementing primary key.

### description / module_name #2  [metadata_id: 3192]

Unique module identifier matching schema names where applicable: dbo, ServerOps, JobFlow, BatchOps, BIDATA, FileOps, Teams, Jira, Orchestrator, ControlCenter, DeptOps.

## Object_Metadata (Table)

### category #0  [metadata_id: 3]

Shared Infrastructure

### data_flow #0  [metadata_id: 4]

Populated manually via INSERT/UPDATE during object creation and documentation maintenance. Read by the DDL reference generator during JSON export to produce schema-level DDL JSON files. Those JSON files are consumed by the reference and troubleshooting pages in the Control Center documentation site.

### description #0  [metadata_id: 1]

Single source of truth for all documentation metadata about database objects across the xFACts platform. Replaces extended properties as the documentation content source. Fed into the DDL JSON export by the DDL reference generator, rendered automatically on reference and troubleshooting pages.

### design_note #1  [metadata_id: 20]
Title: Single Source for All Documentation Content

All documentation metadata lives in this table — object descriptions, column descriptions, design rationale, operational queries, status definitions, and relationship context. Extended properties (MS_Description) are no longer used. One system, one place to look, one way to update.

### design_note #2  [metadata_id: 21]
Title: Graceful Degradation

The DDL export still reads structural metadata (columns, types, constraints, indexes, FKs) from system catalog views. Object_Metadata provides the documentation layer on top. If a column lacks a description row here, it still appears on the reference page with its structural info — just without commentary. Incomplete is better than incorrect.

### design_note #3  [metadata_id: 22]
Title: Soft Delete Over Hard Delete

Rows are deactivated via is_active = 0 rather than deleted. This preserves audit trail and allows reactivation if content is retired prematurely.

### design_note #4  [metadata_id: 2370]
Title: Duplicate Prevention

A unique filtered index (UX_Object_Metadata_NaturalKey) enforces one active row per natural key combination: schema_name, object_name, object_type, column_name_key, property_type, and sort_order. Scoped to is_active = 1 so deactivated rows do not block new inserts. The column_name_key computed column converts NULL to empty string for clean index behavior since column_name is NULL for object-level rows but populated for column-level rows.

### module #0  [metadata_id: 2]

dbo

### query #1  [metadata_id: 31]
Title: All metadata for a specific object
Description: View everything documented about a single table, procedure, or script.

SELECT property_type, column_name, sort_order, title, description, content
FROM dbo.Object_Metadata
WHERE schema_name = 'ServerOps'
  AND object_name = 'Backup_FileTracking'
  AND is_active = 1
ORDER BY property_type, sort_order;

### query #2  [metadata_id: 32]
Title: Objects missing column descriptions
Description: Find columns that exist in the database but have no description row in Object_Metadata.

SELECT s.name AS schema_name, t.name AS table_name, c.name AS column_name
FROM sys.columns c
INNER JOIN sys.tables t ON t.object_id = c.object_id
INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name IN ('dbo','ServerOps','JobFlow','BatchOps','BIDATA','FileOps','Teams','Jira','Orchestrator','DeptOps')
  AND NOT EXISTS (
      SELECT 1 FROM dbo.Object_Metadata om
      WHERE om.schema_name = s.name
        AND om.object_name = t.name
        AND om.column_name = c.name
        AND om.property_type = 'description'
        AND om.is_active = 1
  )
ORDER BY s.name, t.name, c.column_id;

### query #3  [metadata_id: 33]
Title: Documentation coverage by module
Description: Summary of how many objects and columns have descriptions per schema.

SELECT om.schema_name,
       COUNT(DISTINCT CASE WHEN om.column_name IS NULL AND om.property_type = 'description' THEN om.object_name END) AS objects_documented,
       COUNT(CASE WHEN om.column_name IS NOT NULL AND om.property_type = 'description' THEN 1 END) AS columns_documented,
       COUNT(DISTINCT CASE WHEN om.property_type = 'query' THEN om.object_name END) AS objects_with_queries,
       COUNT(DISTINCT CASE WHEN om.property_type = 'design_note' THEN om.object_name END) AS objects_with_design_notes
FROM dbo.Object_Metadata om
WHERE om.is_active = 1
GROUP BY om.schema_name
ORDER BY om.schema_name;

### description / column_name #5  [metadata_id: 9]

NULL for object-level properties. Populated for column-level descriptions and status values scoped to specific columns. For status values applying to multiple columns, use comma-separated column names.

### description / column_name_key #16  [metadata_id: 2368]

Persisted computed column: ISNULL(column_name, ''). Provides NULL-safe indexing for the unique filtered index UX_Object_Metadata_NaturalKey.

### description / content #10  [metadata_id: 14]

The actual documentation content. A description paragraph, a full SQL query, a status value meaning, a data flow narrative. Content type is determined by property_type.

### description / created_by #13  [metadata_id: 17]

Who created the row (auto-populated from login)

### description / created_dttm #12  [metadata_id: 16]

When the row was created

### description / description #9  [metadata_id: 13]

Optional short explanation providing context for the content. Used for queries (what the query shows) and design notes (brief summary). NULL when content is self-explanatory.

### description / is_active #11  [metadata_id: 15]

Soft delete flag. Inactive rows are excluded from JSON export. Use this instead of DELETE to preserve audit trail.

### description / metadata_id #1  [metadata_id: 5]

Unique identifier for each metadata row

### description / modified_by #15  [metadata_id: 19]

Who last updated the row (auto-populated from login)

### description / modified_dttm #14  [metadata_id: 18]

When the row was last updated

### description / object_name #3  [metadata_id: 7]

Name of the documented object: table name, procedure name, script filename, etc.

### description / object_type #4  [metadata_id: 8]

Kind of object: Table, Procedure, Trigger, DDL Trigger, XE Session, Script

### description / property_type #6  [metadata_id: 10]

What kind of documentation content this row holds. Controls how the export proc and loader handle the row.

### status_value / property_type #1  [metadata_id: 23]
Title: description

Object or column description. When column_name is NULL, describes the object. When column_name is populated, describes that specific column.

### status_value / property_type #2  [metadata_id: 24]
Title: module

Which module owns this object. Values match schema names: dbo, ServerOps, JobFlow, BatchOps, BIDATA, FileOps, Teams, Jira, Orchestrator, DeptOps.

### status_value / property_type #3  [metadata_id: 25]
Title: category

Functional grouping within a module. Examples: Backup, Index, Activity_XE, Activity_DMV, Disk, Replication for ServerOps. Shared Infrastructure, RBAC for dbo.

### status_value / property_type #4  [metadata_id: 26]
Title: data_flow

Paragraph describing how data enters, moves through, and exits this object. Names the scripts that write to it, the processes that read from it, and what the Control Center displays from it.

### status_value / property_type #5  [metadata_id: 27]
Title: design_note

Explanation of a non-obvious architectural or design decision. Title holds the topic name. Content holds the rationale.

### status_value / property_type #6  [metadata_id: 28]
Title: query

Common operational query. Title holds the query name. Description holds what the query shows or when to use it. Content holds the full copy-paste-ready SQL.

### status_value / property_type #7  [metadata_id: 29]
Title: status_value

Definition of a valid status or type value for a check-constrained column. Title holds the value itself. Column_name identifies which column(s) it applies to. Content holds what the value means and when it is set.

### status_value / property_type #8  [metadata_id: 30]
Title: relationship_note

Cross-object relationship context that foreign key metadata alone does not convey. Title holds the related object name. Content explains the operational relationship.

### description / schema_name #2  [metadata_id: 6]

Schema the documented object belongs to: dbo, ServerOps, JobFlow, BatchOps, etc.

### description / sort_order #7  [metadata_id: 11]

Display ordering within a property type for a given object. 0-based. Column descriptions use ordinal position. Design notes, queries, and status values use logical sequence.

### description / title #8  [metadata_id: 12]

Context-dependent label. Query name for queries, topic name for design notes, status value string for status_value rows. NULL for types that do not need a label (description, data_flow, module, category).

## Object_Registry (Table)

### category #0  [metadata_id: 3138]

Shared Infrastructure

### data_flow #0  [metadata_id: 3150]

Rows are inserted when new objects are created during platform development. Bulk-seeded during the versioning rearchitecture with all existing platform objects. The Admin page System Metadata modal reads Object_Registry to show the object catalog for each component. Future potential: documentation pipeline and file consolidation scripts could use object_path as a source-of-truth for file locations.

### description #0  [metadata_id: 3136]

Complete asset inventory of every object in the xFACts platform. Each row represents an individual database object, PowerShell script, Control Center file, or documentation asset, linked to its parent component via component_name. Serves as the definitive catalog of what exists and where it lives.

### design_note #1  [metadata_id: 3151]
Title: Object category and type hierarchy
Description: Two-tier classification system for flexible filtering.

object_category provides broad grouping (Database, PowerShell, WebAsset, Documentation) for high-level filtering. object_type provides specific classification (Table, Procedure, Script, Route, API, JavaScript, CSS, HTML, etc.) for detailed inventory queries. Both are constrained via CHECK constraints to prevent freeform values.

### design_note #2  [metadata_id: 3152]
Title: object_path as source of truth
Description: Centralized location tracking for all platform assets.

Database objects store their schema name in object_path (dbo, ServerOps, etc.). Files store their full filesystem path. This makes Object_Registry the single source of truth for where any object lives, enabling future automation of documentation publishing, file consolidation, and deployment scripts that currently hardcode paths.

### design_note #3  [metadata_id: 3153]
Title: Shared objects across components
Description: How objects that serve multiple components are handled.

Some objects logically participate in multiple components (e.g., Collect-ServerHealth.ps1 serves both ServerOps.ServerHealth and ServerOps.Disk, Send-DiskHealthSummary.ps1 similarly). Each object has one row in Object_Registry linked to its primary component. The description field can note shared usage. This avoids duplication while maintaining a clean one-to-one object-to-component mapping.

### module #0  [metadata_id: 3137]

dbo

### query #1  [metadata_id: 3184]
Title: All objects for a component
Description: Lists every registered object within a specific component.

SELECT object_name, object_category, object_type, object_path, description
FROM dbo.Object_Registry
WHERE component_name = 'ServerOps.Index'
  AND is_active = 1
ORDER BY object_category, object_type, object_name;

### query #2  [metadata_id: 3185]
Title: Platform inventory by category and type
Description: Full breakdown of all active objects across the platform.

SELECT object_category, object_type, COUNT(*) AS [count]
FROM dbo.Object_Registry
WHERE is_active = 1
GROUP BY object_category, object_type
ORDER BY object_category, object_type;

### query #3  [metadata_id: 3186]
Title: Find an object across the platform
Description: Search for an object by partial name match. Useful for finding which component owns a particular script or table.

SELECT component_name, object_name, object_category, object_type, object_path
FROM dbo.Object_Registry
WHERE object_name LIKE '%BackupStatus%'
  AND is_active = 1;

### query #4  [metadata_id: 3187]
Title: Objects with file paths for a module
Description: Lists all file-based objects (scripts, CC files, docs) with their paths for a given module. Useful for deployment and consolidation scripts.

SELECT component_name, object_name, object_type, object_path
FROM dbo.Object_Registry
WHERE module_name = 'ServerOps'
  AND object_category != 'Database'
  AND is_active = 1
ORDER BY component_name, object_type, object_name;

### relationship_note #1  [metadata_id: 3154]
Title: Component_Registry

Object_Registry has a foreign key to Component_Registry on component_name. Every object must belong to a registered component.

### relationship_note #2  [metadata_id: 3155]
Title: Object_Metadata

Database objects in Object_Registry should have corresponding Object_Metadata entries for documentation. The object_name and schema (from object_path) map to Object_Metadata.object_name and schema_name respectively.

### description / component_name #3  [metadata_id: 3141]

Parent component this object belongs to. FK to Component_Registry.component_name.

### description / created_by #14  [metadata_id: 3149]

Who registered this object. Auto-populated via SUSER_SNAME() default.

### description / created_dttm #13  [metadata_id: 3148]

When this object was registered. Auto-populated via default.

### description / description #8  [metadata_id: 3146]

Brief description of what this object does.

### description / is_active #12  [metadata_id: 3147]

Soft delete flag. 1 = active, 0 = retired/dropped.

### status_value / is_active #1  [metadata_id: 3156]
Title: 1

Object is active and in use. Default value on INSERT.

### status_value / is_active #2  [metadata_id: 3157]
Title: 0

Object has been retired, dropped, or decommissioned. Row preserved for historical reference.

### description / module_name #2  [metadata_id: 3140]

Functional module this object belongs to: dbo, ServerOps, JobFlow, BatchOps, BIDATA, FileOps, Teams, Jira, Orchestrator, ControlCenter, DeptOps.

### description / object_category #5  [metadata_id: 3143]

Broad classification: Database, PowerShell, WebAsset, Documentation.

### status_value / object_category #1  [metadata_id: 3158]
Title: Database

SQL Server objects: tables, procedures, triggers, views, functions.

### status_value / object_category #2  [metadata_id: 3159]
Title: PowerShell

PowerShell scripts (.ps1) and modules (.psm1) in the automation layer.

### status_value / object_category #3  [metadata_id: 3160]
Title: WebAsset

Control Center files: route pages, API endpoints, JavaScript, CSS.

### status_value / object_category #4  [metadata_id: 3161]
Title: Documentation

Documentation site files: HTML pages, doc-specific JS and CSS.

### description / object_name #4  [metadata_id: 3142]

Name of the individual object. Database objects use their bare SQL name without schema prefix; file components use their filename with extension.

### description / object_path #7  [metadata_id: 3145]

Where to find this object. Schema name for database objects (e.g., dbo, ServerOps). Full filesystem path for files (e.g., E:\xFACts\scripts\collectors\Collect-DMVMetrics.ps1).

### description / object_type #6  [metadata_id: 3144]

Specific object type within its category: Table, Procedure, Trigger, View, Function, Script, Route, API, Module, JavaScript, CSS, HTML.

### description / registry_id #1  [metadata_id: 3139]

Auto-incrementing primary key.

### description / scope #10  [metadata_id: 5089]

Whether a source file's content is LOCAL to the file or SHARED across its zone; NULL for database objects.

### description / scope_tier #11  [metadata_id: 5094]

Identifies whether a shared scope chrome object is a platform wide resource or if it is scoped to a module. This determines the file's spec requirements.

### description / zone #9  [metadata_id: 5088]

The resolution universe a source file belongs to: cc, docs, standalone, or exempt; NULL for database objects.

## Protection_ViolationLog (Table)

### category #0  [metadata_id: 1677]

Shared Infrastructure

### data_flow #0  [metadata_id: 2124]

Populated by TR_xFACts_ProtectCriticalObjects via an autonomous transaction through the xFACts_Loopback linked server. When a protected DDL operation is intercepted, the trigger calls sp_LogProtectionViolation through the loopback, which runs in a separate transaction. This ensures the violation is logged even though the trigger then issues a ROLLBACK of the original DDL statement. Rows are append-only.

### description #0  [metadata_id: 81]

Audit table capturing all blocked DDL operations on protected xFACts objects. When the protection trigger prevents a DROP or ALTER operation, the attempted action is logged here for security review.

### design_note #1  [metadata_id: 2125]
Title: Autonomous Transaction via Loopback

DDL triggers that ROLLBACK face a fundamental problem: any data modifications within the trigger are also rolled back. The loopback linked server pattern (calling sp_LogProtectionViolation via xFACts_Loopback) creates a separate database session. The INSERT commits independently, surviving the trigger's ROLLBACK of the offending DDL.

### design_note #2  [metadata_id: 2126]
Title: Guaranteed Logging

If the loopback logging fails for any reason, the trigger still blocks the DDL operation. Protection is never compromised by logging failures. The logging is best-effort but the protection is absolute.

### module #0  [metadata_id: 1573]

dbo

### query #1  [metadata_id: 2127]
Title: Recent violations
Description: Shows blocked DDL attempts within the last 7 days.

SELECT violation_id, violation_dttm, username, object_name,
       event_type, LEFT(sql_text, 200) AS sql_preview
FROM dbo.Protection_ViolationLog
WHERE violation_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY violation_dttm DESC;

### query #2  [metadata_id: 2128]
Title: Violations by user
Description: Summary of blocked operations per user for security review.

SELECT username, COUNT(*) AS violation_count,
       MIN(violation_dttm) AS first_violation,
       MAX(violation_dttm) AS last_violation
FROM dbo.Protection_ViolationLog
GROUP BY username
ORDER BY violation_count DESC;

### relationship_note #1  [metadata_id: 2129]
Title: TR_xFACts_ProtectCriticalObjects

Source. The DDL trigger intercepts protected operations and logs the attempt to this table before issuing ROLLBACK.

### relationship_note #2  [metadata_id: 2130]
Title: sp_LogProtectionViolation

The INSERT is performed by this procedure, called through the xFACts_Loopback linked server to ensure the log entry commits in a separate transaction from the rolled-back DDL.

### description / event_type #5  [metadata_id: 3659]

Type of DDL operation that was blocked (e.g., DROP_TABLE, ALTER_TABLE, DROP_PROCEDURE). Captured from the DDL trigger event data.

### description / object_name #4  [metadata_id: 3658]

Name of the protected object targeted by the blocked DDL operation. Captured from the DDL trigger event data.

### description / sql_text #6  [metadata_id: 862]

Complete SQL statement that was blocked

### description / username #3  [metadata_id: 3657]

Windows login of the user who attempted the blocked DDL operation. Captured from the DDL trigger event data.

### description / violation_dttm #2  [metadata_id: 3656]

When the blocked DDL operation was attempted. Captured by the protection trigger at the moment of interception.

### description / violation_id #1  [metadata_id: 861]

PK

## RBAC_ActionGrant (Table)

### category #0  [metadata_id: 1678]

RBAC

### data_flow #0  [metadata_id: 2206]

Rows are manually inserted when exceptions to the standard tier-based permissions are needed. The RBAC cache loads all active grants at startup. During action permission evaluation, the middleware first checks grant overrides before falling back to tier-based defaults. DENY grants are evaluated before ALLOW grants, and DENY always wins when both exist for the same user/action.

### description #0  [metadata_id: 75]

Action-level permission overrides for the Control Center RBAC framework. Provides fine-grained ALLOW and DENY grants at the role or individual user level, supplementing the tier-based permissions defined in RBAC_ActionRegistry.

### design_note #1  [metadata_id: 2207]
Title: DENY Takes Precedence

When both ALLOW and DENY exist for the same user/action combination, DENY wins. This implements the principle of least privilege — it is safer to accidentally over-restrict than to accidentally over-permit.

### design_note #2  [metadata_id: 2208]
Title: Role vs User Scope

Most grants should be at the ROLE level. User-level grants (grant_scope = 'USER') are the escape hatch for situations where creating a new AD group and role mapping would be overkill. The check constraint enforces that exactly one of role_id or username is populated.

### design_note #3  [metadata_id: 2209]
Title: Grant Evaluation Order

The middleware evaluates: (1) user-level DENY, (2) role-level DENY, (3) user-level ALLOW, (4) role-level ALLOW, (5) tier-based default from RBAC_PermissionMapping + RBAC_ActionRegistry. The first match wins.

### module #0  [metadata_id: 1574]

dbo

### query #1  [metadata_id: 2214]
Title: All active grants with action details
Description: Shows every override with the action it applies to.

SELECT ag.grant_type, ag.grant_scope, 
       COALESCE(r.role_name, ag.username) AS grantee,
       ar.action_name, ar.page_route, ag.description
FROM dbo.RBAC_ActionGrant ag
JOIN dbo.RBAC_ActionRegistry ar ON ar.action_id = ag.action_id
LEFT JOIN dbo.RBAC_Role r ON r.role_id = ag.role_id
WHERE ag.is_active = 1
ORDER BY ag.grant_type DESC, ar.page_route, ar.action_name;

### relationship_note #1  [metadata_id: 2215]
Title: RBAC_ActionRegistry

Parent table. action_id references RBAC_ActionRegistry.action_id. Identifies which action the grant applies to.

### relationship_note #2  [metadata_id: 2216]
Title: RBAC_Role

Optional parent. role_id references RBAC_Role.role_id when grant_scope = 'ROLE'. NULL when grant_scope = 'USER'.

### description / action_id #4  [metadata_id: 786]

Foreign key to RBAC_ActionRegistry. Identifies the action being granted or denied

### description / created_by #10  [metadata_id: 792]

Who created the grant

### description / created_dttm #9  [metadata_id: 791]

When the grant was created

### description / description #8  [metadata_id: 790]

Explanation of why this grant exists

### description / grant_id #1  [metadata_id: 783]

Unique identifier for the grant

### description / grant_scope #3  [metadata_id: 785]

ROLE (applies to a role) or USER (applies to a specific user)

### status_value / grant_scope #1  [metadata_id: 2212]
Title: ROLE

Grant applies to all users who hold the specified role. The standard approach for most overrides.

### status_value / grant_scope #2  [metadata_id: 2213]
Title: USER

Grant applies to a specific AD username. The exception path for one-off permissions that do not justify a new AD group.

### description / grant_type #2  [metadata_id: 784]

ALLOW or DENY. DENY always takes precedence over ALLOW

### status_value / grant_type #1  [metadata_id: 2210]
Title: ALLOW

Grants access to an action the user would not normally have based on their tier. Example: ReadOnly users get ALLOW for kill-zombie because everyone loves killing zombie connections.

### status_value / grant_type #2  [metadata_id: 2211]
Title: DENY

Revokes access to an action the user would normally have. Always takes precedence over ALLOW. Example: PowerUser gets DENY for bulk-toggle-tasks because bulk operations on production flows are admin-only.

### description / is_active #7  [metadata_id: 789]

Whether this grant is currently in effect

### description / modified_by #12  [metadata_id: 794]

Who last modified the grant

### description / modified_dttm #11  [metadata_id: 793]

When the grant was last modified

### description / role_id #5  [metadata_id: 787]

Foreign key to RBAC_Role. Populated when grant_scope = 'ROLE'

### description / username #6  [metadata_id: 788]

AD username without domain prefix. Populated when grant_scope = 'USER'

## RBAC_ActionRegistry (Table)

### category #0  [metadata_id: 1679]

RBAC

### data_flow #0  [metadata_id: 2196]

Rows are manually inserted when new protected API endpoints are created in the Control Center. The RBAC cache loads all active actions at startup. When an API route handler executes, it looks up the endpoint path and HTTP method in the cache to find the action's required_tier and page_route. The user's tier for that page (from RBAC_PermissionMapping) determines default access, with RBAC_ActionGrant providing overrides.

### description #0  [metadata_id: 71]

Registry of protectable actions in the Control Center. Defines which API endpoints require permission checks, what page they belong to, and what tier is required to execute them.

### design_note #1  [metadata_id: 2197]
Title: Configuration-Driven Action Protection

Before this table existed, action permission checks required hardcoded parameters at every API endpoint. Adding a new protected action meant code changes. With the registry, adding a protected endpoint is a single INSERT and the route handler only needs one line of code that reads everything else from the cached registry.

### design_note #2  [metadata_id: 2198]
Title: Endpoint as Unique Key

The combination of api_endpoint and http_method uniquely identifies an action. The route handler looks up permission requirements from $WebEvent.Path and $WebEvent.Method without knowing anything about the action's name or tier. action_name serves as the human-readable business key used in audit logs and ActionGrant overrides.

### module #0  [metadata_id: 1575]

dbo

### query #1  [metadata_id: 2202]
Title: All registered actions by page
Description: Shows every protected API endpoint grouped by parent page.

SELECT page_route, action_name, api_endpoint, http_method, required_tier, description
FROM dbo.RBAC_ActionRegistry
WHERE is_active = 1
ORDER BY page_route, action_name;

### relationship_note #1  [metadata_id: 2203]
Title: RBAC_ActionGrant

Child table. RBAC_ActionGrant.action_id references RBAC_ActionRegistry.action_id for ALLOW/DENY overrides on specific actions.

### relationship_note #2  [metadata_id: 2204]
Title: RBAC_PermissionMapping

Logical relationship. page_route values match entries in RBAC_PermissionMapping. The user's tier on the parent page determines their default access to the action.

### relationship_note #3  [metadata_id: 2205]
Title: RBAC_AuditLog

action_name from this table appears in RBAC_AuditLog entries when action-level permission checks are logged.

### description / action_id #1  [metadata_id: 709]

Unique identifier for the action

### description / action_name #2  [metadata_id: 710]

Business key for the action (e.g., 'kill-zombie', 'toggle-task'). Used in audit logs and ActionGrant references

### description / api_endpoint #3  [metadata_id: 711]

Full API path (e.g., '/api/server-health/kill-zombies')

### description / created_by #10  [metadata_id: 718]

Who registered the action

### description / created_dttm #9  [metadata_id: 717]

When the action was registered

### description / description #7  [metadata_id: 715]

What this action does

### description / http_method #4  [metadata_id: 712]

HTTP method: POST, PUT, or DELETE

### description / is_active #8  [metadata_id: 716]

Whether this action is currently enforced

### description / modified_by #12  [metadata_id: 720]

Who last modified the action

### description / modified_dttm #11  [metadata_id: 719]

When the action was last modified

### description / page_route #5  [metadata_id: 713]

Parent page route for tier resolution (e.g., '/server-health')

### description / required_tier #6  [metadata_id: 714]

Minimum tier required: admin, operate, or view

### status_value / required_tier #1  [metadata_id: 2199]
Title: admin

Only users with admin tier on the parent page can execute. Used for dangerous or configuration-level actions.

### status_value / required_tier #2  [metadata_id: 2200]
Title: operate

Users with operate or admin tier can execute. The default for most standard workflow actions.

### status_value / required_tier #3  [metadata_id: 2201]
Title: view

Any user with access to the page can execute. Used for actions that are safe for everyone, typically paired with ALLOW grants for broader access.

## RBAC_AuditLog (Table)

### category #0  [metadata_id: 1680]

RBAC

### data_flow #0  [metadata_id: 2221]

Populated by the Control Center RBAC middleware during permission evaluation. Verbosity is controlled by the GlobalConfig setting ControlCenter.rbac_audit_verbosity: 'denials_only' logs only DENIED and WOULD_DENY events, 'all' logs every permission check. Rows are append-only. The ad_groups and resolved_roles columns capture the user's state at event time as denormalized comma-separated strings.

### description #0  [metadata_id: 132]

Logs permission evaluation events from the Control Center RBAC framework. Captures access denials, authentication events, and optionally all permission checks for compliance and troubleshooting.

### design_note #1  [metadata_id: 2222]
Title: Denormalized State Capture

The user's AD groups and resolved roles are stored as comma-separated strings rather than normalized references. This captures the exact permission state at the time of the event, preserving accuracy even if roles, group memberships, or mappings change later.

### design_note #2  [metadata_id: 2223]
Title: Three Enforcement Modes

The RBAC framework supports disabled (no checks), audit (checks run but only log, never block), and enforce (checks run and block unauthorized access). During the audit-to-enforce transition, WOULD_DENY events provide visibility into what would be blocked before anyone gets locked out.

### design_note #3  [metadata_id: 2224]
Title: Complementary to API_RequestLog

API_RequestLog captures all HTTP requests for traffic and performance analysis. RBAC_AuditLog focuses specifically on authorization decisions — who was blocked, why, and what permissions they had. Together they provide complete request + authorization visibility.

### module #0  [metadata_id: 1576]

dbo

### query #1  [metadata_id: 2235]
Title: Recent denials
Description: Shows blocked or would-be-blocked events in the last 7 days.

SELECT event_type, username, page_route, action_name,
       required_tier, user_tier, result, detail, event_dttm
FROM dbo.RBAC_AuditLog
WHERE result IN ('DENIED', 'WOULD_DENY')
  AND event_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY event_dttm DESC;

### query #2  [metadata_id: 2236]
Title: Audit mode impact assessment
Description: Shows how many users and pages would be affected by enabling enforcement.

SELECT username, page_route, action_name,
       COUNT(*) AS occurrence_count
FROM dbo.RBAC_AuditLog
WHERE result = 'WOULD_DENY'
  AND event_dttm >= DATEADD(DAY, -7, GETDATE())
GROUP BY username, page_route, action_name
ORDER BY occurrence_count DESC;

### relationship_note #1  [metadata_id: 2237]
Title: RBAC_ActionRegistry

Logical relationship. action_name values in audit entries correspond to RBAC_ActionRegistry.action_name. No physical foreign key since the audit log must persist even if actions are removed.

### relationship_note #2  [metadata_id: 2238]
Title: API_RequestLog

Complementary table. API_RequestLog captures HTTP request metrics; RBAC_AuditLog captures authorization decisions. Together they provide complete request-level visibility.

### relationship_note #3  [metadata_id: 2239]
Title: GlobalConfig

The ControlCenter.rbac_audit_verbosity setting controls logging volume. 'denials_only' keeps the table lean during normal operation; 'all' provides complete audit coverage when needed.

### description / action_name #7  [metadata_id: 1478]

Action being attempted. NULL for page-level access checks

### description / ad_groups #4  [metadata_id: 1475]

Comma-separated list of the user's AD groups at time of event

### description / audit_id #1  [metadata_id: 1472]

Unique identifier for the audit event

### description / client_ip #12  [metadata_id: 1483]

Client IP address

### description / detail #11  [metadata_id: 1482]

Additional context about the decision

### description / event_dttm #13  [metadata_id: 1484]

When the event occurred

### description / event_type #2  [metadata_id: 1473]

Type of event (see Event Types below)

### status_value / event_type #1  [metadata_id: 2225]
Title: LOGIN_SUCCESS

User successfully authenticated via Active Directory.

### status_value / event_type #2  [metadata_id: 2226]
Title: LOGIN_FAILURE

Active Directory authentication failed.

### status_value / event_type #3  [metadata_id: 2227]
Title: ACCESS_DENIED

User lacks page-level permission. Logged in enforce mode.

### status_value / event_type #4  [metadata_id: 2228]
Title: ACCESS_AUDIT

User would lack page-level permission. Logged in audit mode without blocking.

### status_value / event_type #5  [metadata_id: 2229]
Title: ACTION_DENIED

User lacks action-level permission. Logged in enforce mode.

### status_value / event_type #6  [metadata_id: 2230]
Title: ACTION_AUDIT

User would lack action-level permission. Logged in audit mode without blocking.

### status_value / event_type #7  [metadata_id: 2231]
Title: PERMISSION_CHANGE

RBAC table configuration was modified through the admin interface.

### description / page_route #6  [metadata_id: 1477]

Page route being accessed. NULL for login events

### description / required_tier #8  [metadata_id: 1479]

Minimum tier required for the page/action

### description / resolved_roles #5  [metadata_id: 1476]

Comma-separated list of roles resolved from AD groups

### description / result #10  [metadata_id: 1481]

Outcome: ALLOWED, DENIED, or WOULD_DENY (audit mode)

### status_value / result #1  [metadata_id: 2232]
Title: ALLOWED

Permission check passed. Action or page access was granted.

### status_value / result #2  [metadata_id: 2233]
Title: DENIED

Permission check failed in enforce mode. Access was blocked.

### status_value / result #3  [metadata_id: 2234]
Title: WOULD_DENY

Permission check failed in audit mode. Access was allowed but the event was logged for impact assessment.

### description / user_tier #9  [metadata_id: 1480]

User's resolved tier for the page

### description / username #3  [metadata_id: 1474]

AD username of the user. NULL for unauthenticated events

## RBAC_DepartmentRegistry (Table)

### category #0  [metadata_id: 1681]

RBAC

### data_flow #0  [metadata_id: 2217]

Rows are manually inserted when a new department is onboarded to the Control Center. The middleware uses this table to validate department-scoped access and to render navigation elements appropriate to each user. The department_key value is the join point to RBAC_RoleMapping.department_scope.

### description #0  [metadata_id: 115]

Registry of departmental pages in the Control Center. Maps department identifiers to their page routes and display names.

### design_note #1  [metadata_id: 2218]
Title: Department Key as URL Slug

The department_key is a URL-friendly slug (e.g., 'business-services') used both as the RBAC_RoleMapping.department_scope join key and as part of the page route path. This keeps URLs clean and routing simple without needing a separate URL-to-department lookup.

### module #0  [metadata_id: 1577]

dbo

### query #1  [metadata_id: 2219]
Title: Active departments with role mapping count
Description: Shows registered departments and how many role mappings exist for each.

SELECT dr.department_key, dr.department_name, dr.page_route,
       COUNT(rm.mapping_id) AS role_mapping_count
FROM dbo.RBAC_DepartmentRegistry dr
LEFT JOIN dbo.RBAC_RoleMapping rm ON rm.department_scope = dr.department_key
                                  AND rm.is_active = 1
WHERE dr.is_active = 1
GROUP BY dr.department_key, dr.department_name, dr.page_route
ORDER BY dr.department_name;

### relationship_note #1  [metadata_id: 2220]
Title: RBAC_RoleMapping

Logical relationship. RBAC_RoleMapping.department_scope matches department_key to scope roles to specific departments. No physical foreign key — validated at the application layer.

### description / created_by #7  [metadata_id: 1343]

Who registered the department page

### description / created_dttm #6  [metadata_id: 1342]

When the department page was registered

### description / department_id #1  [metadata_id: 1337]

Unique identifier for the department

### description / department_key #2  [metadata_id: 1338]

URL-friendly identifier (e.g., 'business-services'). Matches RBAC_RoleMapping.department_scope

### description / department_name #3  [metadata_id: 1339]

Display name (e.g., 'Business Services')

### description / is_active #5  [metadata_id: 1341]

Whether this department page is currently active

### description / modified_by #9  [metadata_id: 1345]

Who last modified the department page

### description / modified_dttm #8  [metadata_id: 1344]

When the department page was last modified

### description / page_route #4  [metadata_id: 1340]

Control Center page route (e.g., '/departmental/business-services')

## RBAC_NavRegistry (Table)

### category #0  [metadata_id: 4947]

RBAC

### data_flow #0  [metadata_id: 4948]

Rows are manually inserted when new CC pages are added to the platform. The Get-NavBarHtml helper function (xFACts-Helpers.psm1) reads this table at startup, joined with RBAC_NavSection for section grouping and with RBAC_PermissionMapping for per-user filtering, to render navigation HTML across all CC route files. Home.ps1 reads the same data filtered by show_on_home=1 to render the tile grid. Cached alongside other RBAC data with 5-minute refresh.

### description #0  [metadata_id: 4945]

Master inventory of Control Center pages with navigation metadata. Each row represents a CC page with its display label, page title, description, section grouping, sort order, optional documentation page link, and visibility flags controlling whether it appears in the page-level nav bar and the Home page tile grid. Joined with RBAC_PermissionMapping to filter visible pages per user role.

### design_note #1  [metadata_id: 4964]
Title: Three-Field Text Model

Three separate text columns serve different rendering contexts: nav_label (compact, fits in horizontal nav bar), display_title (prominent page header and tile heading), and description (longer subtitle and tile description). Most pages have nav_label = display_title, but separating them allows the nav bar to use abbreviations while the page header remains formal.

### design_note #2  [metadata_id: 4965]
Title: Decoupled Visibility Flags

show_in_nav and show_on_home are independent flags rather than a combined visibility mode. This allows pages like /client-portal to render as a Home tile but not in the horizontal nav (accessed only from Home), or /admin to be cataloged in the registry without rendering anywhere standard.

### design_note #3  [metadata_id: 4966]
Title: Home Excluded by Convention

The root route / is intentionally not stored in RBAC_NavRegistry. Home is treated as the universal first link in the nav bar by the Get-NavBarHtml helper function rather than as a registered page. This avoids special-case sort_order handling and keeps the registry as a clean catalog of destination pages.

### design_note #4  [metadata_id: 4967]
Title: doc_page_id Convention

The doc_page_id column stores the slug, not the full URL. Helper code constructs /docs/pages/{doc_page_id}.html. This matches the doc_page_id convention used in Component_Registry and centralizes the URL pattern in one place — if the docs URL pattern changes, only the helper updates, not the data.

### design_note #5  [metadata_id: 4968]
Title: Permission Filtering at Render Time

RBAC_NavRegistry does not store permissions. The helper function joins this table with RBAC_PermissionMapping at render time to filter pages to those the current user can access. This separates "what pages exist" (NavRegistry) from "who can access them" (PermissionMapping), and avoids data duplication between the two RBAC concerns.

### module #0  [metadata_id: 4946]

dbo

### query #1  [metadata_id: 4971]
Title: All active pages by section
Description: Lists all active nav registry rows grouped by section in render order.

SELECT 
    ns.section_label,
    nv.sort_order,
    nv.page_route,
    nv.nav_label,
    nv.display_title,
    nv.show_in_nav,
    nv.show_on_home
FROM dbo.RBAC_NavRegistry nv
JOIN dbo.RBAC_NavSection ns ON ns.section_key = nv.section_key
WHERE nv.is_active = 1 AND ns.is_active = 1
ORDER BY ns.section_sort_order, nv.sort_order;

### query #2  [metadata_id: 4972]
Title: NavRegistry vs PermissionMapping coverage check
Description: Identifies pages registered in NavRegistry that have no corresponding RBAC_PermissionMapping row, and vice versa. Both should be in sync — orphans on either side indicate a registration gap.

WITH nav_pages AS (
    SELECT DISTINCT page_route FROM dbo.RBAC_NavRegistry WHERE is_active = 1
),
perm_pages AS (
    SELECT DISTINCT page_route 
    FROM dbo.RBAC_PermissionMapping 
    WHERE is_active = 1 AND page_route NOT IN ('*', '/')
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

### query #3  [metadata_id: 4973]
Title: Pages visible to a specific user (preview)
Description: Shows what pages a specific user would see in nav and home, accounting for both NavRegistry visibility flags and their RBAC permissions.

DECLARE @username VARCHAR(100) = 'dcota';

WITH user_routes AS (
    SELECT DISTINCT pm.page_route
    FROM dbo.RBAC_PermissionMapping pm
    JOIN dbo.RBAC_RoleMapping rm ON rm.role_id = pm.role_id
    -- Note: this is a simplified check; the real middleware also resolves
    -- AD groups, this query is for preview/diagnostic purposes only.
    WHERE pm.is_active = 1 AND rm.is_active = 1
)
SELECT 
    ns.section_label,
    nv.nav_label,
    nv.show_in_nav,
    nv.show_on_home,
    CASE WHEN ur.page_route IS NOT NULL THEN 'yes' ELSE 'no' END AS user_has_permission
FROM dbo.RBAC_NavRegistry nv
JOIN dbo.RBAC_NavSection ns ON ns.section_key = nv.section_key
LEFT JOIN user_routes ur ON ur.page_route = nv.page_route
WHERE nv.is_active = 1
ORDER BY ns.section_sort_order, nv.sort_order;

### relationship_note #1  [metadata_id: 4969]
Title: RBAC_NavSection

Parent table. RBAC_NavRegistry.section_key references RBAC_NavSection.section_key via FK. Determines section grouping and accent styling.

### relationship_note #2  [metadata_id: 4970]
Title: RBAC_PermissionMapping

Logical relationship (no physical FK). NavRegistry.page_route is joined to RBAC_PermissionMapping.page_route at render time to filter the visible page set per user role. Pages in NavRegistry without corresponding PermissionMapping rows would be rendered for nobody.

### description / created_by #13  [metadata_id: 4961]

Who registered this page. Auto-populated via SUSER_SNAME() default.

### description / created_dttm #12  [metadata_id: 4960]

When this page was registered. Auto-populated via default.

### description / description #5  [metadata_id: 4953]

Longer descriptive text used for the page subtitle and Home page tile description. NULL when no description is needed.

### description / display_title #4  [metadata_id: 4952]

Display title used for the page H1 header and the Home page tile heading. Often matches nav_label but may differ when the nav-bar abbreviation is too short for prominent display.

### description / doc_page_id #8  [metadata_id: 4956]

Documentation page slug used to build the docs link. Helper function constructs URL as /docs/pages/{doc_page_id}.html. NULL means no documentation link is rendered for this page.

### description / is_active #11  [metadata_id: 4959]

Soft delete flag. 0 = retired or future page, fully hidden from all rendering but preserved for historical reference.

### description / modified_by #15  [metadata_id: 4963]

Who last modified this page. NULL until first update.

### description / modified_dttm #14  [metadata_id: 4962]

When this page was last modified. NULL until first update.

### description / nav_id #1  [metadata_id: 4949]

Auto-incrementing primary key.

### description / nav_label #3  [metadata_id: 4951]

Short label displayed in the horizontal nav bar. Optimized for compact horizontal display (e.g., "Apps/Int" rather than "Applications & Integration").

### description / page_route #2  [metadata_id: 4950]

CC route path (e.g., /server-health, /departmental/business-services). Joins to RBAC_PermissionMapping.page_route for permission filtering. Unique within the table.

### description / section_key #6  [metadata_id: 4954]

Foreign key to RBAC_NavSection.section_key. Determines which top-level grouping this page belongs to.

### description / show_in_nav #9  [metadata_id: 4957]

Controls visibility in the horizontal page-level nav bar. 1 = appears in nav, 0 = hidden from nav (e.g., admin gear targets, tile-only access pages).

### description / show_on_home #10  [metadata_id: 4958]

Controls visibility as a tile on the Home page. 1 = appears as tile, 0 = hidden from Home (e.g., admin pages, deep-link-only utility pages).

### description / sort_order #7  [metadata_id: 4955]

Numeric ordering within the page section. Increments of 10 for easy insertion of new pages without renumbering. Lower values render first.

## RBAC_NavSection (Table)

### category #0  [metadata_id: 4930]

RBAC

### data_flow #0  [metadata_id: 4931]

Rows are manually inserted when a new top-level navigation grouping is needed. The Get-NavBarHtml helper function (xFACts-Helpers.psm1) reads this table at startup, joined with RBAC_NavRegistry, to render section-grouped navigation links across all CC pages and Home page tile groupings. The accent_class column drives section-level visual styling via CSS classes defined in engine-events.css. Cached alongside other RBAC data with 5-minute refresh.

### description #0  [metadata_id: 4928]

Section groupings for the dynamic Control Center navigation. Each section represents a top-level grouping of CC pages (Platform, Departmental Pages, Tools, Administration) with display order and visual accent styling. Referenced by RBAC_NavRegistry to organize page rows into sections.

### design_note #1  [metadata_id: 4942]
Title: Section vs. Page Separation

Section-level metadata (label, color, ordering) is stored separately from page-level metadata (RBAC_NavRegistry) to avoid duplication. All pages within a section share the same accent styling and label, so storing it once at the section level keeps the data normalized. Adding a new section is a single INSERT here; pages reference it via the section_key foreign key.

### design_note #2  [metadata_id: 4943]
Title: Color via CSS Class Not Hex

The accent_class column stores a CSS class name rather than a literal color value. This decouples presentation (colors, hover effects, dark mode variants) from data, allowing visual changes without database updates. Class definitions live in engine-events.css.

### module #0  [metadata_id: 4929]

dbo

### relationship_note #1  [metadata_id: 4944]
Title: RBAC_NavRegistry

Child table. RBAC_NavRegistry.section_key references RBAC_NavSection.section_key via FK. Each nav registry row belongs to exactly one section.

### description / accent_class #5  [metadata_id: 4936]

CSS class name applied to section elements for visual styling (color theme). Class definitions live in engine-events.css. NULL means no section-level accent styling.

### description / created_by #8  [metadata_id: 4939]

Who registered this section. Auto-populated via SUSER_SNAME() default.

### description / created_dttm #7  [metadata_id: 4938]

When this section was registered. Auto-populated via default.

### description / is_active #6  [metadata_id: 4937]

Soft delete flag. 0 = retired section, hidden from rendering but preserved for historical reference.

### description / section_id #1  [metadata_id: 4932]

Auto-incrementing primary key.

### description / section_key #2  [metadata_id: 4933]

URL-safe identifier used as foreign key target by RBAC_NavRegistry.section_key. Examples: platform, departmental, tools, admin.

### description / section_label #3  [metadata_id: 4934]

Display text rendered as section header on the Home page tile grid. Also used as the conceptual label for nav-bar separator areas.

### description / section_sort_order #4  [metadata_id: 4935]

Numeric ordering for section display. Increments of 10 for easy insertion of new sections without renumbering. Lower values render first.

## RBAC_PermissionMapping (Table)

### category #0  [metadata_id: 1682]

RBAC

### data_flow #0  [metadata_id: 2186]

Rows are manually inserted when configuring page access for roles. The RBAC middleware cache loads all active permissions at startup. When a user requests a page, the middleware resolves their roles (from RBAC_RoleMapping) and checks this table to determine their highest permission tier for that page. The tier controls both page visibility in navigation and action availability on the page.

### description #0  [metadata_id: 121]

Defines what each role can do on each Control Center page. Maps roles to pages with a permission tier that controls whether the user can view, operate, or administer the page.

### design_note #1  [metadata_id: 2187]
Title: Wildcard Route for Admin

The Admin role uses page_route = '*' to grant access to all pages without needing a row per page. This simplifies administration and ensures Admin access is never accidentally omitted from a new page.

### design_note #2  [metadata_id: 2188]
Title: Tier Hierarchy Resolution

admin > operate > view. When a user has multiple roles (e.g., ReadOnly platform-wide + DeptStaff for a department), the middleware takes the highest applicable tier for each page. A user is never downgraded by having additional roles.

### design_note #3  [metadata_id: 2189]
Title: API Route Inheritance

Page routes are stored as exact paths (e.g., '/server-health'). API routes under a page inherit the parent page's permission — '/api/server-health/*' checks against '/server-health'. This avoids needing separate permission rows for every API endpoint.

### module #0  [metadata_id: 1578]

dbo

### query #1  [metadata_id: 2193]
Title: Permission matrix (role x page)
Description: Shows the complete authorization matrix.

SELECT r.role_name, pm.page_route, pm.permission_tier
FROM dbo.RBAC_PermissionMapping pm
JOIN dbo.RBAC_Role r ON r.role_id = pm.role_id
WHERE pm.is_active = 1
ORDER BY r.display_order, pm.page_route;

### relationship_note #1  [metadata_id: 2194]
Title: RBAC_Role

Parent table. role_id references RBAC_Role.role_id. Each permission row assigns one role a tier on one page.

### relationship_note #2  [metadata_id: 2195]
Title: RBAC_ActionRegistry

Logical relationship. RBAC_ActionRegistry.page_route values match entries in this table. The user's tier on a page determines their default access to actions registered under that page.

### description / created_by #7  [metadata_id: 1420]

Who created the permission

### description / created_dttm #6  [metadata_id: 1419]

When the permission was created

### description / is_active #5  [metadata_id: 1418]

Whether this permission is currently in effect

### description / modified_by #9  [metadata_id: 1422]

Who last modified the permission

### description / modified_dttm #8  [metadata_id: 1421]

When the permission was last modified

### description / page_route #3  [metadata_id: 1416]

Page route this permission applies to. Use '*' for all pages

### description / permission_id #1  [metadata_id: 1414]

Unique identifier for the permission

### description / permission_tier #4  [metadata_id: 1417]

Permission level: admin, operate, or view

### status_value / permission_tier #1  [metadata_id: 2190]
Title: admin

Full access to the page including all administrative and destructive actions.

### status_value / permission_tier #2  [metadata_id: 2191]
Title: operate

Standard workflow access. Can perform normal operational actions but not administrative functions.

### status_value / permission_tier #3  [metadata_id: 2192]
Title: view

Read-only access. Page is visible in navigation but no action buttons are rendered.

### description / role_id #2  [metadata_id: 1415]

Foreign key to RBAC_Role

## RBAC_Role (Table)

### category #0  [metadata_id: 1683]

RBAC

### data_flow #0  [metadata_id: 2170]

Rows are manually inserted when new roles are defined. The RBAC middleware cache loads all active roles at Control Center startup. RBAC_RoleMapping references role_id to connect AD groups to roles. RBAC_PermissionMapping references role_id to define page-level access. RBAC_ActionGrant references role_id for role-scoped ALLOW/DENY overrides.

### description #0  [metadata_id: 102]

Role definitions for the xFACts Control Center RBAC framework. Each role represents a permission tier that determines what users can see and do.

### design_note #1  [metadata_id: 2171]
Title: Three-Tier Permission Model

Three tiers cover the vast majority of use cases: admin (full access including destructive actions), operate (standard workflow actions), view (read-only). Finer-grained control is handled through RBAC_ActionGrant rather than creating additional tiers.

### design_note #2  [metadata_id: 2172]
Title: Platform vs Departmental Roles

The same table holds both platform-wide roles (Admin, PowerUser, StandardUser, ReadOnly) and departmental roles (DeptManager, DeptStaff). The distinction is made in RBAC_RoleMapping through the department_scope column, not in the role definition itself. This enables role reuse across departments.

### module #0  [metadata_id: 1579]

dbo

### query #1  [metadata_id: 2176]
Title: All active roles with tier
Description: Shows the role hierarchy by display order.

SELECT role_id, role_name, role_tier, display_order, description
FROM dbo.RBAC_Role
WHERE is_active = 1
ORDER BY display_order;

### relationship_note #1  [metadata_id: 2177]
Title: RBAC_RoleMapping

Child table. RBAC_RoleMapping.role_id references RBAC_Role.role_id. Maps AD groups to roles with optional department scoping.

### relationship_note #2  [metadata_id: 2178]
Title: RBAC_PermissionMapping

Child table. RBAC_PermissionMapping.role_id references RBAC_Role.role_id. Defines what tier each role has on each page.

### relationship_note #3  [metadata_id: 2179]
Title: RBAC_ActionGrant

Child table. RBAC_ActionGrant.role_id references RBAC_Role.role_id for role-scoped ALLOW/DENY overrides on specific actions.

### description / created_by #8  [metadata_id: 1192]

Who created the role

### description / created_dttm #7  [metadata_id: 1191]

When the role was created

### description / description #5  [metadata_id: 1189]

What this role provides access to

### description / display_order #4  [metadata_id: 1188]

Sort order for UI rendering. Lower numbers appear first

### description / is_active #6  [metadata_id: 1190]

Whether this role is currently in use

### description / role_id #1  [metadata_id: 1185]

Unique identifier for the role

### description / role_name #2  [metadata_id: 1186]

Unique role name (e.g., Admin, PowerUser, DeptStaff)

### description / role_tier #3  [metadata_id: 1187]

Permission tier: admin, operate, or view

### status_value / role_tier #1  [metadata_id: 2173]
Title: admin

Full access including destructive and configuration actions. Reserved for the Applications Team.

### status_value / role_tier #2  [metadata_id: 2174]
Title: operate

Standard workflow actions: assign requests, close tasks, kill zombie connections. The default for most active users.

### status_value / role_tier #3  [metadata_id: 2175]
Title: view

Read-only access. Can see data and dashboards but cannot perform any actions. Like window shopping for database metrics.

## RBAC_RoleMapping (Table)

### category #0  [metadata_id: 1684]

RBAC

### data_flow #0  [metadata_id: 2180]

Rows are manually inserted when establishing the connection between AD groups and roles. When a user logs in, the Control Center middleware captures their AD group memberships, looks them up in this table, and resolves which roles they hold. The resolved roles then drive page access via RBAC_PermissionMapping and action permissions via RBAC_ActionGrant.

### description #0  [metadata_id: 108]

Maps Active Directory security groups to RBAC roles with optional department scoping. This is where AD group membership translates into Control Center permissions.

### design_note #1  [metadata_id: 2181]
Title: Separation of Responsibilities

IT Ops manages who is in which AD group (hiring, transfers, departures). The Applications Team manages what those groups mean within the Control Center via these mapping rows. Neither team needs to coordinate with the other for routine access changes.

### design_note #2  [metadata_id: 2182]
Title: Department Scope Mechanism

NULL department_scope means the role applies platform-wide (Admin, PowerUser, etc.). A non-NULL value (e.g., 'business-services') scopes the role to that department's pages only. This enables the same DeptStaff role definition to be reused across departments while the AD group provides department-specific context.

### module #0  [metadata_id: 1580]

dbo

### query #1  [metadata_id: 2183]
Title: All active mappings with role details
Description: Shows which AD groups map to which roles and at what scope.

SELECT rm.ad_group_name, r.role_name, r.role_tier, rm.department_scope
FROM dbo.RBAC_RoleMapping rm
JOIN dbo.RBAC_Role r ON r.role_id = rm.role_id
WHERE rm.is_active = 1
ORDER BY rm.department_scope, r.display_order;

### relationship_note #1  [metadata_id: 2184]
Title: RBAC_Role

Parent table. role_id references RBAC_Role.role_id. Each mapping assigns one AD group to one role.

### relationship_note #2  [metadata_id: 2185]
Title: RBAC_DepartmentRegistry

Logical relationship. The department_scope value matches RBAC_DepartmentRegistry.department_key to scope the role to a specific department's pages. No physical foreign key — validated at the application layer.

### description / ad_group_name #2  [metadata_id: 1262]

Active Directory group name (e.g., XCC-Admin, XCC-BusSvcsStaff)

### description / created_by #7  [metadata_id: 1267]

Who created the mapping

### description / created_dttm #6  [metadata_id: 1266]

When the mapping was created

### description / department_scope #4  [metadata_id: 1264]

Department key this mapping applies to. NULL = platform-wide. Matches RBAC_DepartmentPage.department_key

### description / is_active #5  [metadata_id: 1265]

Whether this mapping is currently in effect

### description / mapping_id #1  [metadata_id: 1261]

Unique identifier for the mapping

### description / modified_by #9  [metadata_id: 1269]

Who last modified the mapping

### description / modified_dttm #8  [metadata_id: 1268]

When the mapping was last modified

### description / role_id #3  [metadata_id: 1263]

Foreign key to RBAC_Role

## ServerRegistry (Table)

### category #0  [metadata_id: 1685]

Shared Infrastructure

### data_flow #0  [metadata_id: 2068]

Rows are manually inserted when onboarding a new SQL Server instance to xFACts. Module feature flags are toggled as modules are enabled for each server. Collect-ServerHealth.ps1 updates last_service_start_dttm from sys.dm_os_sys_info on each collection cycle. Every monitoring script queries ServerRegistry to determine which servers to process based on module-specific feature flags (e.g., serverops_backup_enabled, serverops_maintenance_enabled). DatabaseRegistry references server_id as a foreign key.

### description #0  [metadata_id: 68]

Registry of SQL Server instances managed by xFACts, including connection information and module-level feature flags. This is a shared infrastructure table used by multiple modules.

### design_note #1  [metadata_id: 2069]
Title: Module Feature Flags

Each module has its own enable/disable bit column (serverops_activity_enabled, serverops_backup_enabled, serverops_disk_enabled, serverops_maintenance_enabled, jobflow_enabled, batchops_enabled, fileops_enabled, bidata_enabled). This allows servers to participate in some modules but not others based on their role. All flags default to 0 (disabled), requiring explicit enablement.

### design_note #2  [metadata_id: 2070]
Title: AG Cluster Grouping

The ag_cluster_name field groups servers that belong to the same Always On Availability Group. Both primary and secondary nodes are registered independently since either could hold the primary role at any time. Server ID 0 (AVG-PROD-LSNR) represents the AG listener endpoint, not a physical server.

### design_note #3  [metadata_id: 2071]
Title: Service Start Time Context

The last_service_start_dttm field captures when the SQL Server service last started, sourced from sys.dm_os_sys_info. This provides context for DMV-based statistics like index usage stats which reset on service restart.

### design_note #4  [metadata_id: 4140]
Title: Environment-Based Activation Constraint

CK_ServerRegistry_environment_is_active enforces that only PROD servers can be set to is_active = 1. Non-PROD servers (STAGE, TEST, DEV) are registered for reference by processes that need environment-specific targets but are permanently excluded from orchestrator-managed collection cycles. This prevents accidental enrollment of lower-environment servers in production monitoring.

### module #0  [metadata_id: 1581]

dbo

### query #1  [metadata_id: 2079]
Title: Active servers with module flags
Description: Shows all active servers and which modules are enabled for each.

SELECT server_id, server_name, server_type, environment, ag_cluster_name,
       serverops_activity_enabled, serverops_backup_enabled,
       serverops_disk_enabled, serverops_maintenance_enabled,
       jobflow_enabled, batchops_enabled, fileops_enabled, bidata_enabled
FROM dbo.ServerRegistry
WHERE is_active = 1
ORDER BY server_name;

### query #2  [metadata_id: 2080]
Title: Servers by AG cluster
Description: Groups servers by Availability Group membership.

SELECT ag_cluster_name, server_name, server_type, server_role
FROM dbo.ServerRegistry
WHERE ag_cluster_name IS NOT NULL
  AND is_active = 1
ORDER BY ag_cluster_name, server_type;

### relationship_note #1  [metadata_id: 2081]
Title: DatabaseRegistry

Parent table. DatabaseRegistry.server_id references ServerRegistry.server_id to establish which server hosts each monitored database.

### relationship_note #2  [metadata_id: 2082]
Title: ServerOps.DatabaseConfig

Indirectly related through DatabaseRegistry. ServerOps component-specific settings for databases are linked via DatabaseRegistry.database_id, which links back to ServerRegistry.server_id.

### description / ag_cluster_name #8  [metadata_id: 660]

Availability Group name (NULL for standalone)

### description / api_base_url #27  [metadata_id: 4183]

DM REST API base URL for this server. Populated for APP_SERVER and STANDALONE entries that expose a DM REST API. NULL for SQL_SERVER and AG_LISTENER entries. Used by Tools operations for API call targeting.

### description / batchops_enabled #18  [metadata_id: 668]

Enable batch monitoring (BatchOps module)

### description / bidata_enabled #20  [metadata_id: 670]

Enable BI build monitoring (BIDATA module)

### description / cpu_count #10  [metadata_id: 3225]

Number of logical CPU cores on the server. Used for CPU percentage calculations in DMV workload snapshots.

### description / created_by #32  [metadata_id: 674]

Who registered the server

### description / created_dttm #31  [metadata_id: 673]

When server was registered

### description / description #9  [metadata_id: 661]

Additional notes about the server

### description / dmops_archive_enabled #21  [metadata_id: 3783]

Whether DM archive processing is enabled for this server. Execute-DmArchive.ps1 checks this flag on the target server at startup. 0 = archive processing disabled, 1 = enabled. Independent of other module enable flags.

### description / dmops_shell_purge_enabled #22  [metadata_id: 3865]

Whether shell purge processing is enabled for this server. Execute-DmShellPurge.ps1 checks this flag at startup when running from GlobalConfig target_instance (skipped when TargetInstance parameter is specified manually). 1 = enabled, 0 = disabled.

### description / environment #6  [metadata_id: 658]

Server environment designation. Constrained to PROD, STAGE, TEST, or DEV. Only PROD servers can have is_active = 1 (enforced by CK_ServerRegistry_environment_is_active).

### status_value / environment #1  [metadata_id: 2072]
Title: PROD

Production environment. These servers can be set to is_active = 1 for orchestrator-managed collection. All automated monitoring runs exclusively against PROD servers.

### status_value / environment #2  [metadata_id: 2073]
Title: DEV

Development environment. Cannot be set to is_active = 1 (enforced by CHECK constraint). Available as a target for testing processes via environment-based lookups.

### status_value / environment #3  [metadata_id: 2074]
Title: TEST

Test environment. Cannot be set to is_active = 1 (enforced by CHECK constraint). Used by DmOps archive/shell purge testing and BDL Import testing via environment-based or GlobalConfig target_instance lookups.

### status_value / environment #4  [metadata_id: 2075]
Title: STAGE

Staging environment. Cannot be set to is_active = 1 (enforced by CHECK constraint). Represents the DM staging AG cluster (DM-STAGE-DB / DM-STAGE-REP / AVG-STAGE-LSNR) and associated app servers.

### description / fileops_enabled #19  [metadata_id: 669]

Enable file monitoring (FileOps module)

### description / instance_name #3  [metadata_id: 655]

SQL Server instance name for named instances (NULL = default instance)

### description / is_active #11  [metadata_id: 662]

Controls whether the server is enrolled in orchestrator-managed collection processes. Servers with is_active = 1 are actively monitored by automated collectors in the Orchestrator. Servers with is_active = 0 are registered for reference by other processes but excluded from automated collection. Constrained by CK_ServerRegistry_environment_is_active: only PROD servers can be set to 1.

### status_value / is_active #1  [metadata_id: 4138]
Title: 1

Server is actively enrolled in orchestrator-managed collection processes. Only PROD servers can have this value (enforced by CK_ServerRegistry_environment_is_active). All automated collectors filter on is_active = 1.

### status_value / is_active #2  [metadata_id: 4139]
Title: 0

Server is registered but not enrolled in automated collection. Required for all non-PROD servers (STAGE, TEST, DEV). PROD servers may also be set to 0 to temporarily exclude them from collection without removing the registration.

### description / is_api_primary #28  [metadata_id: 4184]

Marks the default API target for single-server operations in this environment. One primary per environment. All-server operations (e.g., Refresh Drools) iterate all servers with api_base_url populated and tools_enabled = 1.

### description / is_domain_controller #24  [metadata_id: 3227]

Identifies the JBoss domain controller server. The DmOps metrics collector uses this flag to determine which server hosts the Management API endpoint. Only one server should have this set to 1.

### description / jboss_ds_alert_threshold #25  [metadata_id: 3382]

Datasource connection pool alert threshold for JBoss monitoring. When ds_in_use_count equals or exceeds this value for two consecutive snapshots, a CRITICAL Teams alert fires. 0 = alerting disabled for this server. Each server can have an independent threshold to accommodate different workload profiles.

### description / jboss_enabled #23  [metadata_id: 3660]

Enable JBoss application server monitoring for this server. When enabled, Collect-JBossMetrics.ps1 queries datasource pool metrics, undertow throughput, and deployment status via the JBoss Management API.

### description / jobflow_enabled #17  [metadata_id: 667]

Enable job monitoring (JobFlow module)

### description / last_service_start_captured_dttm #30  [metadata_id: 672]

When the service start time was last captured

### description / last_service_start_dttm #29  [metadata_id: 671]

SQL Server service start time from sys.dm_os_sys_info

### description / modified_by #34  [metadata_id: 676]

Who last modified the record

### description / modified_dttm #33  [metadata_id: 675]

When record was last modified

### description / server_id #1  [metadata_id: 653]

Unique identifier for the server

### description / server_name #2  [metadata_id: 654]

Server hostname (must match hostname for WinRM)

### description / server_role #7  [metadata_id: 659]

Description of server's purpose/role

### description / server_type #4  [metadata_id: 656]

Type of server (SQL_SERVER, WINDOWS, AG_LISTENER)

### status_value / server_type #1  [metadata_id: 2076]
Title: SQL_SERVER

Standard SQL Server instance. Default value for new registrations.

### status_value / server_type #2  [metadata_id: 2077]
Title: WINDOWS

Windows server monitored for non-SQL operations (e.g., disk space only).

### status_value / server_type #3  [metadata_id: 2078]
Title: AG_LISTENER

Availability Group listener endpoint. Represents a logical connection point, not a physical server.

### status_value / server_type #4  [metadata_id: 3228]
Title: APP_SERVER

Application server (e.g., JBoss EAP). Monitored for HTTP responsiveness, service state, and application-level metrics by the DmOps module.

### description / serverops_activity_enabled #12  [metadata_id: 663]

Enable Extended Events and DMV collection (ServerOps Activity component)

### description / serverops_backup_enabled #13  [metadata_id: 664]

Enable backup monitoring (ServerOps Backup component)

### description / serverops_dbcc_enabled #16  [metadata_id: 3522]

Enable DBCC CHECKDB execution for this server. When enabled, Execute-DBCC.ps1 processes all active databases from DatabaseRegistry on the day specified by dbcc_run_day.

### description / serverops_disk_enabled #14  [metadata_id: 665]

Enable disk space monitoring (ServerOps Disk component)

### description / serverops_index_enabled #15  [metadata_id: 666]

Enable index maintenance (ServerOps Index component)

### description / sql_edition #5  [metadata_id: 657]

SQL Server edition (Enterprise, Standard) - determines feature availability

### description / tools_enabled #26  [metadata_id: 3933]

Enable Tools module operations for this server. When enabled, the server is available as a target for BDL imports, CDL imports, payment file processing, and other Tools-driven operations. Tools.ServerConfig provides per-server configuration details. 0 = disabled (default), 1 = enabled.

## sp_AddHoliday (Procedure)

### category #0  [metadata_id: 1686]

Shared Infrastructure

### data_flow #0  [metadata_id: 2137]

Accepts a holiday date, name, weekend observation flag, and preview flag. Applies Saturday-to-Friday / Sunday-to-Monday shifts when @ObserveWeekends = 1, appending "(Observed)" to the name. Checks for duplicate dates before inserting into dbo.Holiday. Preview mode (default) shows what would happen without making changes.

### description #0  [metadata_id: 131]

Adds a single holiday to dbo.Holiday with optional weekend observation adjustment. Use for company-specific holidays or one-off closures not covered by sp_GenerateHolidays.

### design_note #1  [metadata_id: 2138]
Title: Preview Mode Default

Like other xFACts procedures, @PreviewOnly defaults to 1. This prevents accidental data changes when testing or exploring. The preview output shows original vs final date, day of week, and whether the holiday already exists.

### design_note #2  [metadata_id: 2139]
Title: Idempotent by Date

The procedure checks for existing holidays on the final date (after any weekend shift). If a holiday already exists on that date, insertion is skipped regardless of name. This makes repeated execution safe.

### module #0  [metadata_id: 1582]

dbo

### relationship_note #1  [metadata_id: 2140]
Title: Holiday

Inserts rows into dbo.Holiday. Used for company-specific holidays or one-off closures not covered by sp_GenerateHolidays.

### relationship_note #2  [metadata_id: 2141]
Title: sp_GenerateHolidays

Complementary procedure. sp_GenerateHolidays handles standard annual US holidays in bulk; sp_AddHoliday handles individual additions.

## sp_GenerateHolidays (Procedure)

### category #0  [metadata_id: 1687]

Shared Infrastructure

### data_flow #0  [metadata_id: 2142]

Accepts a year and preview flag. Calculates fixed-date holidays (New Year's, Independence Day, Veterans Day, Christmas) and floating holidays (Memorial Day, Labor Day, Thanksgiving, Day After Thanksgiving) using calendar arithmetic. Applies weekend observation rules to fixed-date holidays. Checks each date against existing dbo.Holiday rows to prevent duplicates, then inserts new entries.

### description #0  [metadata_id: 130]

Generates standard company holidays for a given year and inserts them into dbo.Holiday. Automatically calculates floating holidays (Memorial Day, Thanksgiving) and applies weekend observation rules.

### design_note #1  [metadata_id: 2143]
Title: Company-Specific Holiday Selection

Only holidays the company actually observes are generated. Some federal holidays (MLK Day, Presidents Day, Columbus Day) are excluded because the company does not observe them. The Day After Thanksgiving is included as a company holiday.

### design_note #2  [metadata_id: 2144]
Title: Idempotent Execution

Running the procedure multiple times for the same year is safe. Existing holidays are detected by date and skipped. This makes the procedure useful for both initial population and verification.

### module #0  [metadata_id: 1583]

dbo

### relationship_note #1  [metadata_id: 2145]
Title: Holiday

Bulk-populates dbo.Holiday with standard US holidays for a given year. The primary method for annual holiday calendar setup.

### relationship_note #2  [metadata_id: 2146]
Title: sp_AddHoliday

Complementary procedure. sp_AddHoliday handles individual additions for company-specific holidays; sp_GenerateHolidays handles the standard annual set.

## sp_LogProtectionViolation (Procedure)

### category #0  [metadata_id: 1688]

Shared Infrastructure

### data_flow #0  [metadata_id: 2147]

Called by TR_xFACts_ProtectCriticalObjects through the xFACts_Loopback linked server. Receives violation details (timestamp, username, object name, event type, SQL text) and performs a simple INSERT into dbo.Protection_ViolationLog. Because the call comes through the loopback, it executes in a separate database session, ensuring the INSERT commits even though the calling trigger issues ROLLBACK.

### description #0  [metadata_id: 50]

Helper procedure that logs DDL protection violations via autonomous transaction. Called by TR_xFACts_ProtectCriticalObjects through a loopback linked server to ensure log entries persist despite the trigger's ROLLBACK.

### design_note #1  [metadata_id: 2148]
Title: Autonomous Transaction Pattern

SQL Server does not support autonomous transactions natively. The loopback linked server (xFACts_Loopback, pointing back to the same instance) creates a separate session. The procedure's INSERT commits when the procedure returns, independent of the caller's transaction state.

### design_note #2  [metadata_id: 2149]
Title: No Error Handling by Design

The procedure contains no TRY/CATCH. If the INSERT fails, the error propagates to the trigger, which catches it silently and proceeds with the DDL ROLLBACK. Protection is never compromised by logging failures.

### module #0  [metadata_id: 1584]

dbo

### relationship_note #1  [metadata_id: 2150]
Title: TR_xFACts_ProtectCriticalObjects

Called exclusively by the protection trigger via the xFACts_Loopback linked server. Not intended for direct execution.

### relationship_note #2  [metadata_id: 2151]
Title: Protection_ViolationLog

Target table. Each call inserts one row capturing the blocked DDL operation details.

## Sync-ClientHierarchy.ps1 (Script)

### category #0  [metadata_id: 4236]

Shared Infrastructure

### data_flow #0  [metadata_id: 4237]

Reads crs5_oltp.dbo.crdtr and crs5_oltp.dbo.crdtr_grp on AVG-PROD-LSNR via a recursive CTE that resolves the entire creditor group hierarchy. Writes to dbo.ClientHierarchy via MERGE (insert new, update changed, delete removed). After the MERGE, stamps last_refreshed_dttm on unchanged rows so the timestamp reflects the sync cycle. Registered in ProcessRegistry for daily orchestrator execution.

### description #0  [metadata_id: 4234]

Rebuilds dbo.ClientHierarchy from crs5_oltp creditor and creditor group tables using a recursive CTE to resolve the full group hierarchy in a single pass. Uses MERGE to insert new creditors, update changed metadata, and delete creditors removed from the source. The CTE walks all groups regardless of soft-delete status, capturing the hierarchy as it exists in DM. Active flags at creditor, parent group, and top parent levels enable discrepancy detection.

### design_note #1  [metadata_id: 4238]
Title: Full Hierarchy Walk

The CTE does not filter on crdtr_grp_sft_dlt_flg. Soft-deleted groups are walked the same as active groups to capture the real DM hierarchy. Active flags at each level (creditor, parent group, top parent) let consumers identify discrepancies without going back to source tables.

### design_note #2  [metadata_id: 4239]
Title: Unresolved Group Safety Net

Creditors whose group chain cannot be resolved through the CTE (e.g., circular references, groups pointing to non-existent parents) fall back to self-reference, the same treatment as standalone creditors in Group 1. This prevents NULL failures in the MERGE while still including the creditor in the table.

### design_note #3  [metadata_id: 4240]
Title: Timestamp Touch Pass

The MERGE only updates rows where column values actually changed. Rows that matched but had no differences are not touched, leaving their last_refreshed_dttm stale. A follow-up UPDATE stamps these rows so last_refreshed_dttm always reflects that the sync ran, enabling staleness detection.

### module #0  [metadata_id: 4235]

dbo

### relationship_note #1  [metadata_id: 4241]
Title: dbo.ClientHierarchy

Target table rebuilt by this script via MERGE. The script is the sole writer to this table.

### relationship_note #2  [metadata_id: 4242]
Title: crs5_oltp.dbo.crdtr

Source table for creditor records. All creditors are included regardless of status.

### relationship_note #3  [metadata_id: 4243]
Title: crs5_oltp.dbo.crdtr_grp

Source table for creditor group hierarchy. The recursive CTE walks this table from top-level groups down to leaf groups. All groups are included regardless of soft-delete flag.

## System_Metadata (Table)

### category #0  [metadata_id: 3164]

Shared Infrastructure

### data_flow #0  [metadata_id: 3172]

Rows are inserted via the Admin page System Metadata modal or directly via SQL during development sessions. The table is append-only — rows are never updated or deleted. The Admin page reads the latest row per component_name to display current versions, and queries full history per component for the version history expansion.

### description #0  [metadata_id: 3162]

Append-only version changelog for xFACts platform components. Each row records a single version bump for one component, capturing what changed and when. Current version for any component is the latest row by metadata_id. Replaces the previous per-object versioning model with component-level tracking.

### design_note #1  [metadata_id: 3173]
Title: Append-only design
Description: Why there is no status column or update trigger.

Unlike the previous System_Metadata table which used ACTIVE/SUPERSEDED status tracking with an auto-supersede trigger, the new table is purely append-only. Current version is determined by querying the latest row (MAX metadata_id or TOP 1 ORDER BY metadata_id DESC) for a given component_name. This eliminates the need for status management, triggers, and the associated complexity.

### design_note #2  [metadata_id: 3174]
Title: Sequential version counter
Description: Three-place counter with no semantic meaning.

Versions follow a three-place sequential pattern: 1.0.0, 1.0.1, ..., 1.0.9, 1.1.0, ..., 1.9.9, 2.0.0. The numbers carry no major/minor/patch semantics — each increment is just the next number. The description field carries all meaning about what changed. This eliminates the decision friction of choosing between major, minor, and patch bumps.

### design_note #3  [metadata_id: 3175]
Title: One bump per session per component
Description: Session-level granularity for version entries.

All changes to a component within a single working session are captured in one version entry. The description lists everything touched. This keeps the changelog meaningful without generating noise from individual file saves.

### module #0  [metadata_id: 3163]

dbo

### query #1  [metadata_id: 3178]
Title: Current version per component
Description: Returns the latest version for every active component. Uses ROW_NUMBER to pick the most recent entry by metadata_id.

SELECT sm.component_name, sm.version, sm.description, sm.deployed_date, sm.deployed_by
FROM dbo.System_Metadata sm
INNER JOIN (
    SELECT component_name, MAX(metadata_id) AS max_id
    FROM dbo.System_Metadata
    GROUP BY component_name
) latest ON sm.metadata_id = latest.max_id
ORDER BY sm.component_name;

### query #2  [metadata_id: 3179]
Title: Full version history for a component
Description: Returns all version entries for a specific component, newest first.

SELECT metadata_id, version, description, deployed_date, deployed_by
FROM dbo.System_Metadata
WHERE component_name = 'ServerOps.Index'
ORDER BY metadata_id DESC;

### query #3  [metadata_id: 3180]
Title: Recent platform activity
Description: Returns the most recent version bumps across all components. Useful for seeing what changed recently.

SELECT TOP 20
    sm.module_name, sm.component_name, sm.version, sm.description,
    sm.deployed_date, sm.deployed_by
FROM dbo.System_Metadata sm
ORDER BY sm.metadata_id DESC;

### query #4  [metadata_id: 3181]
Title: Component version summary with object counts
Description: Combines current version from System_Metadata with object count from Object_Registry. The dashboard view.

SELECT
    cr.module_name, cr.component_name, cr.description,
    COUNT(oreg.registry_id) AS object_count,
    sm.version AS current_version, sm.deployed_date
FROM dbo.Component_Registry cr
LEFT JOIN dbo.Object_Registry oreg
    ON oreg.component_name = cr.component_name AND oreg.is_active = 1
LEFT JOIN (
    SELECT component_name, version, deployed_date,
           ROW_NUMBER() OVER (PARTITION BY component_name ORDER BY metadata_id DESC) AS rn
    FROM dbo.System_Metadata
) sm ON sm.component_name = cr.component_name AND sm.rn = 1
WHERE cr.is_active = 1
GROUP BY cr.module_name, cr.component_name, cr.description, sm.version, sm.deployed_date
ORDER BY cr.module_name, cr.component_name;

### relationship_note #1  [metadata_id: 3176]
Title: Component_Registry

System_Metadata has a foreign key to Component_Registry on component_name. Version entries can only be recorded for registered components.

### relationship_note #2  [metadata_id: 3177]
Title: Legacy.System_Metadata

The previous dbo.System_Metadata table was renamed to Legacy.System_Metadata during the versioning rearchitecture. All historical per-object version data is preserved there. No migration or rollup was attempted — the new table starts at 3.0.0 per component to maintain continuity with legacy version numbering.

### description / component_name #3  [metadata_id: 3167]

Component being versioned. FK to Component_Registry.component_name.

### description / deployed_by #7  [metadata_id: 3171]

Who deployed this version. Auto-populated via SUSER_SNAME() default.

### description / deployed_date #6  [metadata_id: 3170]

When this version was deployed. Auto-populated via GETDATE() default.

### description / description #5  [metadata_id: 3169]

What changed in this version — lists specific objects and files touched.

### description / metadata_id #1  [metadata_id: 3165]

Auto-incrementing primary key. Also serves as a natural ordering key — higher metadata_id means more recent version.

### description / module_name #2  [metadata_id: 3166]

Functional module this version entry belongs to. Matches Component_Registry.module_name.

### description / version #4  [metadata_id: 3168]

Three-place sequential version counter (e.g., 1.0.0, 1.0.1, 1.1.0). No semantic meaning — just the next number. Increments: 1.0.0 through 1.0.9, then 1.1.0 through 1.9.9, then 2.0.0.

## TR_System_Metadata_AutoSupersede (Trigger)

### category #0  [metadata_id: 1690]

Shared Infrastructure

### description #0  [metadata_id: 62]

AFTER INSERT trigger that automatically marks previous versions of objects as SUPERSEDED when a new version is deployed, maintaining version history without manual intervention.

### design_note #1  [metadata_id: 2159]
Title: Three-Column Match

The trigger matches on module_name + component_name + component_type to identify the same object across versions. This three-column key mirrors the UQ_Module_Component_Version unique constraint (which also includes version). Renames produce a different component_name so they are not auto-superseded — rename handling requires manual status updates.

### design_note #2  [metadata_id: 2160]
Title: Timestamp from New Version

The status_changed_date on the superseded row is set to the new version's deployed_date, not GETDATE(). This ensures the supersession timestamp aligns with the deployment timeline, which matters for point-in-time reconstruction queries.

### module #0  [metadata_id: 1586]

dbo

### relationship_note #1  [metadata_id: 2161]
Title: System_Metadata

Parent table. Fires AFTER INSERT on dbo.System_Metadata. Updates previous ACTIVE rows for the same object to SUPERSEDED with superseded_reason = VERSION.

### relationship_note #2  [metadata_id: 2162]
Title: TR_xFACts_ProtectCriticalObjects

This trigger is in the protected triggers list. Attempts to DROP or ALTER it are blocked and logged.

## TR_xFACts_ProtectCriticalObjects (DDL Trigger)

### category #0  [metadata_id: 2136]

Shared Infrastructure

### data_flow #0  [metadata_id: 2163]

Fires on DDL events (DROP_TABLE, ALTER_TABLE, DROP_PROCEDURE, ALTER_PROCEDURE, DROP_VIEW, ALTER_VIEW, DROP_FUNCTION, ALTER_FUNCTION, DROP_TRIGGER, ALTER_TRIGGER). Extracts event details from EVENTDATA() XML. Checks the target object against a hardcoded protected list organized by schema. If protected, calls sp_LogProtectionViolation via the xFACts_Loopback linked server (autonomous transaction), then issues ROLLBACK and RAISERROR.

### description #0  [metadata_id: 2134]

Database-scoped DDL trigger that prevents accidental DROP or ALTER operations on critical xFACts objects. Intercepts DDL commands across all schemas, checks against a hardcoded protected objects list, logs violation attempts via autonomous transaction through the xFACts_Loopback linked server, then rolls back the operation.

### design_note #1  [metadata_id: 2164]
Title: Hardcoded Protection List

Protected objects are maintained as string literals within the trigger definition. This was chosen because all xFACts objects should be protected by default, and anyone with permissions to create objects also has access to modify the trigger. A simple list is easy to audit. New modules must add their objects to the list as part of deployment.

### design_note #2  [metadata_id: 2165]
Title: Self-Protecting

The trigger protects itself. Attempts to DROP or ALTER TR_xFACts_ProtectCriticalObjects are intercepted and blocked. To modify the trigger, it must first be disabled (DISABLE TRIGGER ... ON DATABASE), modified, then re-enabled.

### design_note #3  [metadata_id: 2166]
Title: ORIGINAL_LOGIN() for Identity

The trigger captures the user identity using ORIGINAL_LOGIN() rather than SUSER_SNAME() or SYSTEM_USER. This returns the original login even when context switching via EXECUTE AS, ensuring the actual person who initiated the DDL is recorded.

### module #0  [metadata_id: 2135]

dbo

### relationship_note #1  [metadata_id: 2167]
Title: Protection_ViolationLog

Target audit table. Every blocked DDL operation is logged here with full event details including the SQL text of the blocked command.

### relationship_note #2  [metadata_id: 2168]
Title: sp_LogProtectionViolation

Called via the xFACts_Loopback linked server to perform the INSERT in a separate transaction. This autonomous transaction pattern ensures the log entry survives the trigger's ROLLBACK.

### relationship_note #3  [metadata_id: 2169]
Title: TR_System_Metadata_AutoSupersede

Sibling protected trigger. Both triggers are in each other's protection scope.

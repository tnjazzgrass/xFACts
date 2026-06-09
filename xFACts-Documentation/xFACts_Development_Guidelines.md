# xFACts Development Guidelines

**Version:** 1.5.0  
**Date:** April 29, 2026

The single source of truth for how xFACts platform components are built. Every new module, page, script, and database object should align with these guidelines. Deviations are acceptable when justified -- document them when they occur.

**Primary audience:** Claude (session context for consistent builds).  
**Secondary audience:** Dirk (audit reference to verify alignment).

**Exceptions:** Most guidelines have exceptions -- pages or components that deviate from a standard for documented reasons. Inline notes call these out in context, and **Appendix A** provides a consolidated quick-reference. When looking at existing pages for reference, always check the appendix first to avoid modeling new work after an exception.

---

## 1. Philosophy & Principles

**Document current state only.** Documentation describes what exists today. No roadmap sections, no "planned for future" notes, no version history embedded in content. Version history lives in `dbo.System_Metadata`. Planned work lives in the Backlog Items document. These are the only two homes for that information.

**Minimize hardcoded values.** Don't write "runs every 5 minutes" when you can write "runs on a configurable schedule via ProcessRegistry." Don't write "threshold is 15%" when you can write "threshold is configurable via GlobalConfig." This prevents documentation rot when settings change.

**Single sources of truth.** Every piece of operational data has exactly one home. Process schedules live in `Orchestrator.ProcessRegistry`. Version history lives in `dbo.System_Metadata`. Runtime configuration lives in `dbo.GlobalConfig`. Refresh intervals live in GlobalConfig loaded via a shared API route. Page refresh behavior is defined by the `ENGINE_PROCESSES` map in each page's JavaScript. If information is findable in one of these places, don't duplicate it elsewhere.

**Object_Metadata is the documentation system.** Every database object and every column gets documented in `dbo.Object_Metadata`. This is the single source of truth for all documentation content -- descriptions, data flows, design notes, status values, queries, and relationship context. Extended properties (MS_Description) are deprecated and no longer read by the documentation pipeline. If it's not in Object_Metadata, it doesn't exist in the documentation. See Section 2.9.

**Four file-format specs define conformance.** Each Control Center file type -- CSS, JavaScript, the HTML markup emitted from route, API, and module files, and PowerShell -- has a dedicated specification that defines the single approved way to structure and write that file. Where a language permits several legal ways to express the same thing, the spec picks one as the xFACts standard; the asset-registry populators flag everything else as drift. This serves two goals: it keeps the populators' drift signal meaningful (drift means "does not match the standard," not "one of several valid styles"), and it makes files easier to develop against by giving every file of a given type the same predictable shape. The four specs are the authority for all file-format questions -- this document does not restate their rules, and where build guidance here touches file structure it points to the relevant spec rather than duplicating it. (Example: xFACts JavaScript comments follow the same single comment convention as CSS; any other otherwise-legal JS comment form is flagged as drift.)

**Build what's needed, not frameworks.** Every table, script, and UI component should solve a current problem. If it doesn't serve an active use case today, it doesn't get built today.

**Preview mode by default.** All procedures and scripts that make changes are safe by default. SQL uses `@preview_mode = 1`. PowerShell requires an explicit `-Execute` switch. The orchestrator overrides these for production execution. This allows safe manual testing at any time.

**Capture everything, retain strategically.** Collect more data than you think you need -- storage is cheap, regret is expensive. But apply retention policies so tables don't grow unbounded.

**Consolidate shared patterns.** When the same code block, CSS rule, or behavioral pattern appears in multiple files, it belongs in a shared resource. When building something new, check existing shared resources first -- someone may have already solved that problem. When you find duplication that doesn't have a shared resource yet, create one and immediately add a backlog item to migrate existing instances. The platform grew organically without shared resource standards, so duplication exists across all layers (PowerShell, CSS, JS). The standard going forward is to consolidate, not copy. See Section 3.6 for PowerShell shared resources and Section 5.11 for Control Center shared CSS/JS.

**GitHub is the file access layer.** All platform files are published to a GitHub repository (`tnjazzgrass/xFACts`) and accessed by Claude via the manifest at the start of each session. This replaces manual file uploads to Project Knowledge. The manifest must be fetched without truncation to enable access to all files -- see Section 7.4 for the complete workflow, manifest structure, and known limitations. If GitHub access is unavailable or a specific file cannot be retrieved, the fallback is direct file upload to the chat.

---

## 2. Database Standards

### 2.1 Schema Organization

Each module owns a dedicated database schema. The `dbo` schema holds shared infrastructure objects (ServerRegistry, GlobalConfig, System_Metadata, etc.). There is no "Core" or "Shared" schema -- it's just `dbo`. When creating a new module, create a corresponding schema. The ControlCenter module is an exception -- it's a web application with no database schema, though its components are versioned in System_Metadata.

Within a schema, group related tables using functional prefixes: `Disk_`, `Index_`, `Backup_`, `Activity_`, etc. This creates natural grouping in SSMS object explorer and makes it immediately clear which tables belong together.

**Schema-qualify all object names** in documentation and code: `dbo.ServerRegistry`, `ServerOps.Index_Queue`. No exceptions.

### 2.2 Table Naming Conventions

Tables use functional suffixes that communicate purpose at a glance:

| Suffix | Meaning | Granularity |
|--------|---------|-------------|
| Summary | Batch-level results or per-entity aggregated view | One row per run/batch or per entity |
| Log | Item-level processing records | One row per item processed |
| Status | Current operational state (dashboard) | Usually single-row or per-entity |
| State | Collection/processing position tracking | One row per tracked source |
| History | Point-in-time snapshots / past alerts | Append-only |
| Config | Settings and configuration | Various |
| Registry | Master catalog of managed entities | One row per entity |
| Queue | Pending work items | One row per pending item; removed after processing |
| Schedule | Time-based rules | Various |
| Type | Reference/lookup data | Static list |
| Tracking | Lifecycle state progression | One row per entity, updated through stages |

Key distinctions to get right: Summary is batch-level, Log is item-level. Status is current operational state, State tracks collection/processing position. Registry catalogs entities being managed, Config stores settings. Queue always means pending work -- items leave when processed.

Exceptions are acceptable when a descriptive name is clearer (e.g., names like `Credentials` or `Holiday` that serve a unique purpose and don't benefit from a functional suffix).

### 2.3 Constraint and Index Naming

Every constraint and index follows a standard prefix pattern. These are mandatory -- no exceptions, no creative alternatives:

| Type | Pattern | Example |
|------|---------|---------|
| Primary Key | `PK_TableName` | `PK_Index_Registry` |
| Foreign Key | `FK_ChildTable_ParentTable` | `FK_Index_Registry_DatabaseRegistry` |
| Unique Constraint | `UQ_TableName_Columns` | `UQ_Index_Registry_database_id_index_name` |
| Check Constraint | `CK_TableName_Description` | `CK_Index_Queue_status` |
| Index | `IX_TableName_Purpose` | `IX_Index_Queue_status_priority` |
| Default Constraint | `DF_TableName_column_name` | `DF_Index_Registry_is_active` |

For foreign keys, the child table comes first: `FK_ChildTable_ParentTable`. For check constraints, the description indicates what's being validated. For indexes, the purpose indicates the columns or use case.

When documenting constraints, list them in this order (skip categories that don't exist -- no empty placeholders): Primary Key, Foreign Keys, Unique Constraints, Check Constraints, Indexes, Default Constraints.

### 2.4 DDL Validation Checklist

**CRITICAL:** All new database objects MUST be validated against these standards before DDL generation. No exceptions without discussion.

Before creating any new table, procedure, trigger, or index, verify:

1. **`dbo.Object_Metadata` rows created** -- description, module, category baselines at minimum. Column description rows for every column. Without these, the object is invisible to the documentation system. (Section 2.9)
2. Table name follows functional suffix conventions (Section 2.2)
3. All constraints and indexes follow naming patterns (Section 2.3)
4. `dbo.Object_Registry` row created for the new object, and a `dbo.System_Metadata` version bump recorded on the parent component (Section 2.6)
5. Protection trigger covers the new object if appropriate (Section 2.5)
6. GlobalConfig entries added for any configurable thresholds or settings (Section 2.7)
7. Schema-qualified names used throughout

**When modifying existing objects:** Evaluate whether the change warrants new or updated Object_Metadata content -- column descriptions for new columns, updated `data_flow` if data paths changed, new `status_value` entries for new statuses, updated `design_note` or `relationship_note` if behavior or integrations changed. Structural changes almost always require Object_Metadata updates. This check should be a habit on every modification -- Object_Metadata is only as accurate as the last time someone updated it.

### 2.5 Protection Triggers

Critical database objects are protected by a DDL trigger that prevents accidental DROP or ALTER operations. New objects that are part of the core platform should be added to the protection list. Emergency override capabilities exist but are documented discretely -- they should not be prominently advertised.

### 2.6 Versioning and Object Registration

Every architectural or infrastructure change gets a corresponding version bump in `dbo.System_Metadata`. Content changes (config table values, operational data) do not get versioned. Minor bug fixes are borderline -- ask first.

#### 2.6.1 Registry Hierarchy

Version tracking is built on a four-table hierarchy:

```
dbo.Module_Registry          -- Top-level functional domains (ServerOps, JobFlow, etc.)
  +-- dbo.Component_Registry -- Logical groupings within a module (ServerOps.Backup, ServerOps.Index)
        +-- dbo.Object_Registry -- Individual objects (tables, scripts, CC files)
dbo.System_Metadata          -- Append-only version changelog per component
```

- **Module_Registry** defines functional domains. One row per module. Includes a business-friendly tagline displayed in the admin panel.
- **Component_Registry** groups related objects into versioned units. One row per component. All version bumps happen at this level.
- **Object_Registry** catalogs every individual object (database objects, PowerShell scripts, CC files, documentation assets) and links it to its parent component. Infrastructure config files that affect platform behavior (e.g., `server.psd1`) are also cataloged here, even if they don't need to be included in file exports -- the registry should be comprehensive enough that someone browsing a component's objects can find everything that matters.
- **System_Metadata** is the append-only version changelog. One row per version bump per component. The current version for any component is simply the most recent row.

Components are defined in `dbo.Component_Registry`. The current list is exported to `xFACts_Platform_Registry.md` by `Consolidate-UploadFiles.ps1` and should be available in session context. This is the authoritative reference for component names, module membership, and descriptions -- always check it before querying the database. Query `Component_Registry` directly only if the export is not available:

```sql
SELECT module_name, component_name, description
FROM dbo.Component_Registry
WHERE is_active = 1
ORDER BY module_name, component_name;
```

#### 2.6.2a File Header Standards

Version numbers do not appear in file headers as a hardcoded `Version: X.Y.Z` value. The version lives in `dbo.System_Metadata` at the component level -- embedding a literal version in a file creates a second source of truth that inevitably drifts. This is a platform-wide rule. How each file type expresses its header -- and whether that header carries a System_Metadata pointer line, a `.COMPONENT` declaration, or neither -- is defined by the standard governing that file type, below.

**SQL objects (stored procedures, triggers, functions):**
- Keep the descriptive header block (Object, Type, Purpose)
- Keep the CHANGELOG block -- it provides useful developer context when reading the file directly
- Replace any `Version: X.Y.Z` line with: `Version: Tracked in dbo.System_Metadata (component: SchemaName.ComponentName)`
- Changelog entries are informal notes (date + what changed), not tied to version numbers

**PowerShell files (all `.ps1` and `.psm1` -- Control Center routes, APIs, and modules; standalone automation scripts; and shared libraries):** Header construct, changelog placement, and the component declaration are defined by the PowerShell spec. Build the header to that spec rather than to any pattern described here -- the spec is authoritative and the populators enforce it.

**Control Center CSS and JavaScript files:** Header construct is defined by the CSS spec and the JavaScript spec respectively. Build to those specs.

**Documentation files (HTML pages, CSS, JS):**
- No version numbers, no changelogs

**Version line transition:** Existing files still carry the old `Version: X.Y.Z` format. These are updated incrementally as files are touched during normal development -- there is no bulk migration. For file types governed by a spec, "updated" means brought into conformance with that spec's header rules; for SQL objects, it means adopting the System_Metadata pointer form shown above.

#### 2.6.2b File Encoding Standard

All `.ps1`, `.psm1`, `.psd1`, `.js`, `.css`, `.html`, `.md`, and `.sql` files use **CRLF line endings** (the Windows convention, since the platform runs on Windows) and should be saved as **UTF-8**.

**The load-bearing rule is pure-ASCII content.** Within these files, use only ASCII characters (bytes 0x00 through 0x7F) in code, comments, and string literals. This is the requirement that actually matters for reliable GitHub retrieval (see "Why this matters" below). Specifically:

- Use plain hyphens, not em-dashes or en-dashes
- Use straight quotes, not curly/typographic quotes
- Use three dots `...`, not the single-character ellipsis
- Use ASCII arrows like `->` and `=>`, not Unicode arrow characters
- Use `*` or `-` for list bullets in comments, not Unicode bullet characters

**Exception:** HTML entities (`&#NNNN;` or `&name;`) in HTML/heredoc strings are encouraged for non-ASCII display characters since they're pure ASCII in the source. The browser renders them as the intended Unicode character at display time.

**Why this matters:** Non-ASCII characters in source files frequently get corrupted in transit between editors and operating systems with different code-page defaults. A single Windows-1252 byte (such as `0x97` for an em-dash) embedded in an otherwise UTF-8 file is invalid UTF-8 and causes GitHub to classify the file as binary (`application/octet-stream`), which prevents standard tooling from reading it. A real instance of this occurred on April 30, 2026 with `Home.ps1`. Restricting source content to pure ASCII eliminates this entire class of issue.

A note on the BOM: a UTF-8 byte-order mark is not itself the reliable cause of the binary-classification problem -- non-ASCII content (or genuinely non-UTF-8 encoding) is what consistently breaks web retrieval. A BOM may occasionally interfere, but on its own it is comparatively harmless, and some editors (Windows PowerShell ISE among them) silently re-add a BOM every time a `.ps1` file is saved. Fighting the editor over the BOM is not worth the effort; keeping the content pure ASCII is. Strip a BOM if it is convenient to do so, but treat the ASCII-content rule as the one that is non-negotiable.

**How to verify a file is clean:**

```powershell
# PowerShell -- flag any file containing non-ASCII bytes
Get-ChildItem -Recurse -Include *.ps1,*.psm1,*.js,*.css,*.html,*.md,*.sql |
    Where-Object {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        $bytes | Where-Object { $_ -gt 0x7F } | Select-Object -First 1
    } |
    Select-Object FullName
```

```bash
# Bash -- same check
grep -rlP '[\x80-\xFF]' --include='*.ps1' --include='*.js' --include='*.css' \
    --include='*.html' --include='*.md' --include='*.sql' .
```

If a scan finds an offending file, open it in a text editor that surfaces encoding (VS Code shows it in the bottom-right status bar), locate the non-ASCII character, and replace it with its ASCII equivalent or HTML entity. Saving as UTF-8 (without a BOM if the editor allows it) is preferred, but the essential fix is removing the non-ASCII content.

#### 2.6.3 Versioning Model

Versioning is **component-level**. A single version bump covers all objects touched within a component during a session. The description field carries all meaning about what changed.

**Sequential counter:** Versions follow a three-place sequential pattern with no semantic meaning: `3.0.0 -> 3.0.1 -> ... -> 3.0.9 -> 3.1.0 -> ... -> 3.9.9 -> 4.0.0`. Each increment is just the next number. There is no major/minor/patch distinction -- the description explains the change.

**One bump per session per component.** All changes to a component within a single working session are captured in one version entry. The description lists everything touched. Save version bumps for the end of the session -- additional changes may occur that should be captured in the same bump.

**Cross-component changes:** When a change serves a specific component (e.g., adding a GlobalConfig entry for Index maintenance), bump the component the change serves (ServerOps.Index), not Engine.SharedInfrastructure.

#### 2.6.4 During Development

While actively working on changes, no versioning actions are needed. Just build, test, and deploy as normal. Keep track of what you're changing -- the description you write later needs to capture it.

If modifying an existing SQL object or PowerShell script that has a CHANGELOG block, add an informal entry at the top:

```
CHANGELOG
---------
2026-03-07  Added Python script execution support to launch function
2026-03-01  Initial implementation
```

These are developer notes -- no version numbers, no formal structure.

#### 2.6.5 Registering New Objects

When creating new database objects, scripts, or CC files:

1. Add the object to `dbo.Object_Registry` with the correct `module_name`, `component_name`, `object_category`, `object_type`, `object_path`, and `description`. The `module_name` must match the parent module from `dbo.Component_Registry` -- it is a NOT NULL column.

```sql
INSERT INTO dbo.Object_Registry 
    (module_name, component_name, object_name, object_category, object_type, object_path, description)
VALUES 
    ('ModuleName', 'ModuleName.ComponentName', 'ObjectName', 'Category', 'Type', 
     'E:\path\to\file', 'Brief description of the object.');
```

Common `object_category` / `object_type` combinations:

| Category | Type | Examples |
|----------|------|---------|
| Database | Table, Procedure, Trigger, Function, View | Schema objects |
| PowerShell | Script, Module, Config | `.ps1`, `.psm1`, `.psd1` files |
| WebAsset | Route, API, JavaScript, CSS | Control Center files |
| Documentation | HTML, CSS, JavaScript | Documentation site files |

2. Create `dbo.Object_Metadata` baseline rows (description, module, category, column descriptions) per Section 2.9.
3. Record a version bump on the parent component at end of session (Section 2.6.7).

New components require a `dbo.Component_Registry` INSERT first, then a `System_Metadata` baseline row (version 1.0.0, description "Initial component baseline"). New modules require a `dbo.Module_Registry` INSERT first. These are SQL-only operations, though the Admin UI also supports adding components.

#### 2.6.6 What Gets Versioned

| Versioned | Not Versioned |
|-----------|---------------|
| New tables, procedures, triggers, views, functions | GlobalConfig value changes |
| Structural changes to existing objects (new columns, altered logic) | Operational data (batch status, alert queue entries) |
| New or modified PowerShell scripts | Object_Metadata content enrichment (descriptions, queries) |
| Control Center page changes (route, API, JS, CSS) | Documentation HTML content updates |
| New components or modules | Bug fixes that don't change structure (borderline -- ask first) |
| New infrastructure config files (e.g., server.psd1) | Credential data rows (CredentialServices, Credentials) |

#### 2.6.7 End of Session: Version Bumps

At the end of a development session, record what changed. This is the **only** time versioning actions are needed beyond changelog entries during development.

**Preferred method: Admin UI**

1. Open Administration page -> System Metadata panel
2. Expand the module -> expand the component
3. Type a description of everything that changed in this session
4. Click Insert -- version auto-increments

**Alternative: SQL INSERT (for scripted deployments or bulk operations)**

```sql
INSERT INTO dbo.System_Metadata (module_name, component_name, version, description)
VALUES ('ServerOps', 'ServerOps.Index', '3.0.1', 'Added Index_RetentionConfig table, updated Execute-IndexMaintenance.ps1 retention logic');
```

The table is append-only -- no triggers, no status columns. The current version is always the latest row per component_name.

**What to include in the description:** What was added, changed, or fixed. Which specific files or objects were touched (briefly). Keep it concise but complete enough that someone reading the history understands the change.

**Rules:**
- One bump per component per session -- aggregate all changes
- If a session touches multiple components, bump each one separately
- Save bumps for the end of the session to capture everything in one entry
- Cross-component changes: bump the component the change *serves*
- The version number auto-increments sequentially -- no semantic meaning

**Providing bump requests (e.g., from Claude):** Use this format so the person entering the bump knows exactly where to navigate:

> **Module: ControlCenter -> Component: ControlCenter.Admin**
> `Added DM App Server toggle with firewall and SharePoint integration. New GET/POST endpoints, modal UI, CSS styles.`

#### 2.6.8 Querying Versions

```sql
-- Current version per component
SELECT sm.component_name, sm.version, sm.description, sm.deployed_date
FROM dbo.System_Metadata sm
INNER JOIN (
    SELECT component_name, MAX(metadata_id) AS max_id
    FROM dbo.System_Metadata
    GROUP BY component_name
) latest ON sm.metadata_id = latest.max_id
ORDER BY sm.component_name;

-- Full history for a component
SELECT version, description, deployed_date, deployed_by
FROM dbo.System_Metadata
WHERE component_name = 'ServerOps.Index'
ORDER BY metadata_id DESC;
```

#### 2.6.9 Legacy Data

The previous per-object System_Metadata table is preserved as `Legacy.System_Metadata`. All historical version data remains accessible there. No migration was performed -- the new table started fresh at version 3.0.0 per component to maintain continuity with legacy version numbering.

#### 2.6.10 Session Checklist

For any development session:

- [ ] Add informal changelog entries to modified SQL/PowerShell files
- [ ] Create `Object_Registry` rows for any new objects (Section 2.6.5 -- remember `module_name` is required)
- [ ] Create `Object_Metadata` baseline rows for any new objects (Section 2.9)
- [ ] At end of session: version bump each affected component via Admin UI or SQL
- [ ] If new component: `Component_Registry` + `System_Metadata` baseline first
- [ ] If new module: `Module_Registry` first

### 2.7 GlobalConfig Patterns

Settings in `dbo.GlobalConfig` follow a consistent structure:

- **module_name:** The owning module (e.g., `ServerOps`, `ControlCenter`, `dbo`). For GlobalConfig lookups in scripts, check for all three legacy module name possibilities as a stopgap: `dbo`, `Core`, `Shared` -- some historical entries may use older naming.
- **category:** The component within the module (e.g., `Disk`, `Activity_XE`, `Index`). NULL only if the setting is truly module-wide with no component affiliation.
- **setting_name:** Lowercase with underscores (e.g., `fragmentation_threshold`, `retention_days`).
- **description:** Required for every setting. No blank descriptions. This should be *one line* only because it appears in a modal description column with limited space. Don't get wordy - just describe what it is and what it's for clearly and succinctly.
- **data_type:** Required for every setting. Current settings include ALERT_MODE (custom for alerting), BIT, DECIMAL, INT, VARCHAR. See current contents of GlobalConfig in PlatformRegistry for further clarification.

New configurable thresholds, intervals, and behavioral flags should always go in GlobalConfig rather than being hardcoded in scripts or procedures. The standard pattern for Control Center refresh intervals is `refresh_<pagename>_seconds` -- see Section 4.1 for details.

**Category convention for page-specific admin functions:** Settings that support administrative actions on a specific page use category `Admin` under that page's owning module. This distinguishes them from operational configs (where category matches the functional component, e.g., `App`, `Disk`, `Index`). These are typically state values driven by admin actions, but the category applies to any setting that supports page-specific administrative functionality. Example: `dm_sharepoint_active_server` lives under module `JBoss`, category `Admin` -- it tracks which server the SharePoint link points to, managed via an admin-level toggle on the DM Monitoring page. Admin-category settings commonly have `ui_visible = 0` since they aren't dashboard-tunable. If a direct query returns more settings than the UI shows for a module, `Admin` category entries are the likely reason.

### 2.8 Extended Properties (Deprecated)

**Extended properties (MS_Description) are deprecated.** All documentation content now lives in `dbo.Object_Metadata` (Section 2.9). The DDL reference generation procedure (`sp_GenerateDDLReference` v2.0+) reads descriptions from Object_Metadata, not from extended properties.

Legacy extended properties exist on objects created before the Object_Metadata migration. These are inert -- nothing reads them. A cleanup pass to remove them is on the backlog as a low-priority item.

**Do not add new extended properties.** All descriptions -- object-level and column-level -- go into Object_Metadata. See Section 2.9 for INSERT patterns.

### 2.9 Object_Metadata Standards

`dbo.Object_Metadata` is the single source of truth for all documentation content about database objects and PowerShell scripts. It stores everything the documentation system needs: object descriptions, column descriptions, data flows, design decisions, status value definitions, common queries, and relationship notes. Combined with the structural DDL information from `sp_GenerateDDLReference` (columns, types, constraints, indexes), it produces complete auto-generated reference documentation pages.

#### Table Structure

```
dbo.Object_Metadata
+-- metadata_id          INT IDENTITY        -- PK
+-- schema_name          VARCHAR(128)        -- Schema: dbo, ServerOps, JobFlow, etc.
+-- object_name          VARCHAR(128)        -- Object: Backup_FileTracking, sp_Backup_Monitor, etc.
+-- object_type          VARCHAR(50)         -- Table, Procedure, Trigger, Function, View, Script
+-- column_name          VARCHAR(128) NULL   -- NULL = object-level. Populated = column-level.
+-- property_type        VARCHAR(50)         -- What kind of content (see Property Types below)
+-- sort_order           INT DEFAULT 0       -- Display order within property type for this object
+-- title                VARCHAR(200) NULL   -- Context-dependent label (see Property Types)
+-- description          VARCHAR(500) NULL   -- Optional short explanation for content
+-- content              VARCHAR(MAX)        -- The actual documentation content
+-- is_active            BIT DEFAULT 1       -- Soft delete. 0 = excluded from export.
+-- created_dttm         DATETIME            -- Auto-populated
+-- created_by           VARCHAR(100)        -- Auto-populated
+-- modified_dttm        DATETIME            -- Auto-populated
+-- modified_by          VARCHAR(100)        -- Auto-populated
```

#### Baseline Rows (Mandatory for Every Object)

Every new object gets three mandatory baseline rows at creation time. Without these, the object will not appear in the JSON export or on the reference documentation pages.

```sql
INSERT INTO dbo.Object_Metadata 
    (schema_name, object_name, object_type, column_name, property_type, sort_order, title, description, content)
VALUES
('SchemaName', 'ObjectName', 'Table', NULL, 'description', 0, NULL, NULL,
 'One-paragraph description of what this object does.'),
('SchemaName', 'ObjectName', 'Table', NULL, 'module', 0, NULL, NULL, 'ModuleName'),
('SchemaName', 'ObjectName', 'Table', NULL, 'category', 0, NULL, NULL, 'CategoryName');
```

Change `object_type` to match: `Table`, `Procedure`, `Trigger`, `Function`, `View`, or `Script`. For scripts, `object_name` uses the full filename with `.ps1` extension (see Section 3.5).

**For database objects created after the bulk migration:** The migration auto-created baselines from existing extended properties for all objects that existed at migration time. All new objects created after the migration need manual baseline inserts -- description, module, category at minimum, plus a column description row for every column. This is the same process as scripts. If the Object_Metadata rows aren't created with the DDL, the object is undocumented.

#### Property Types

Each property type uses specific columns in a specific way. The JSON export maps these columns to the rendered output.

**description** -- Object or column description text.
- `column_name`: NULL for object-level, column name for column-level
- `title`: NULL
- `description`: NULL
- `content`: The description text
- `sort_order`: 0 for object-level. Column ordinal position for column-level (1, 2, 3...).
- Already populated for all migrated objects and columns. Update existing rows if the current description needs improvement, but don't re-insert.

**module** -- Which xFACts module owns this object.
- `column_name`: NULL
- `content`: Module name -- must match an active entry in `dbo.Module_Registry`. Refer to `xFACts_Platform_Registry.md` in the project files for the current list, or query `SELECT module_name FROM dbo.Module_Registry WHERE is_active = 1` if the file is unavailable.
- Already populated for migrated objects. Should not need changes.

**category** -- Functional grouping within a module.
- `column_name`: NULL
- `content`: Category name. Categories are module-specific (e.g., ServerOps uses functional categories like `Backup`, `Index`, `Replication`; dbo uses `Shared Infrastructure`, `RBAC`, etc.). Refer to existing Object_Metadata rows for the module to see established categories, or check the schema JSON files in the project files.
- Already populated for migrated objects. Should not need changes.

**data_flow** -- How data enters, moves through, and exits this object.
- `column_name`: NULL
- `content`: A paragraph naming the scripts that write to it, the processes that read from it, and what the Control Center displays from it. Be specific about script names and table names.
- `sort_order`: 0 (one per object)
- This is the most important enrichment property -- it connects the object to the rest of the system.
- JSON mapping: renders as an info panel titled "Data Flow" on the reference page.
- **Example (Backup_FileTracking):** "Collect-BackupStatus.ps1 discovers new backups in msdb.backupset on each monitored server and inserts records with PENDING network and AWS statuses, capturing compressed_size_bytes from the actual file at collection time. Process-BackupNetworkCopy.ps1 claims PENDING network records, copies files to the network share, and updates status to COMPLETED (or FAILED). Process-BackupAWSUpload.ps1 does the same for S3 uploads. Process-BackupRetention.ps1 evaluates retention rules using backup chain logic, deletes expired files from local and network storage, and records deletion timestamps. The Control Center Backup Monitoring page reads this table for pipeline status display, file counts, and throughput metrics."

**design_note** -- Non-obvious architectural or design decision.
- `column_name`: NULL
- `title`: Topic name (e.g., "Source-Agnostic Detection", "Pipeline Status Pattern")
- `description`: Optional brief summary. NULL is fine if the content is clear.
- `content`: Explanation of why something was built this way, what tradeoff was made, what problem it solves.
- `sort_order`: Sequential starting at 1.
- Zero to many per object. Only add when there's a genuine non-obvious decision. Don't force them.
- JSON mapping: `title` -> `topic`, `description` -> `summary`, `content` -> `note`
- **Where to find these:** Look for tradeoffs, denormalization decisions, why something is a certain data type, or why a particular approach was chosen. In scripts, look for conditional logic, AG-awareness patterns, and error handling that reveal design intent.

**status_value** -- What a valid status or type value means.
- `column_name`: Column name(s) this value applies to. Comma-separated if shared (e.g., `network_copy_status,aws_upload_status`)
- `title`: The actual value (e.g., `PENDING`, `ACTIVE`, `COMPLETED`)
- `content`: What this value means and when it gets set.
- `sort_order`: Sequential starting at 1, in logical order (not alphabetical).
- Add for any column with a CHECK constraint or a defined set of meaningful values.
- JSON mapping: `column_name` -> `column` (grouping header), `title` -> `value`, `content` -> `meaning`
- **Where to find these:** Check constraints on the table are the primary source. Also look for status lifecycle descriptions in script logic where values are set.

**query** -- Common operational query.
- `column_name`: NULL
- `title`: Query name (e.g., "Recent backups with pipeline status")
- `description`: Brief explanation of what the query shows (VARCHAR 500)
- `content`: Full copy-paste-ready SQL. Use doubled single-quotes for string literals (e.g., `''PENDING''`).
- **Formatting:** Queries must use proper multi-line formatting with line breaks and indentation -- never a single continuous line. The content is displayed verbatim on reference pages and used for copy/paste. A single-line stream is unreadable in the reference page code block and unusable when copied. Format as you would write it in a query window.
- `sort_order`: Sequential starting at 1.
- Include queries genuinely useful for operations or troubleshooting. Don't pad with trivial SELECT * queries.
- JSON mapping: `title` -> `name`, `description` -> `description`, `content` -> `sql`
- **Where to find these:** Existing documentation "Common Queries" sections, troubleshooting sections, and queries embedded in operational notes. Also consider what someone would need to look up at 2 AM.

**relationship_note** -- Cross-object relationship context beyond what foreign keys show.
- `column_name`: NULL
- `title`: Related object name (e.g., `Backup_DatabaseConfig`)
- `content`: How these objects interact operationally.
- `sort_order`: Sequential starting at 1.
- `description`: NULL
- Focus on relationships that matter operationally, not every table that shares a column.
- JSON mapping: `title` -> `relatedObject`, `content` -> `note`
- **Where to find these:** Foreign keys are the starting point -- if a table has FKs, there's usually an operational story behind each one. Also look for cross-module references in scripts (Teams queue, Jira queue, ProcessRegistry dependencies).

#### INSERT Patterns

**Data Flow:**
```sql
INSERT INTO dbo.Object_Metadata 
    (schema_name, object_name, object_type, property_type, content)
VALUES ('ServerOps', 'TableName', 'Table', 'data_flow',
    'Description of how data flows through this object.');
```

**Design Notes:**
```sql
INSERT INTO dbo.Object_Metadata 
    (schema_name, object_name, object_type, property_type, sort_order, title, content)
VALUES 
('ServerOps', 'TableName', 'Table', 'design_note', 1, 
    'Topic Name',
    'Explanation of the design decision.'),
('ServerOps', 'TableName', 'Table', 'design_note', 2, 
    'Another Topic',
    'Another explanation.');
```

**Status Values:**
```sql
INSERT INTO dbo.Object_Metadata 
    (schema_name, object_name, object_type, column_name, property_type, sort_order, title, content)
VALUES 
('ServerOps', 'TableName', 'Table', 'status_column', 'status_value', 1, 
    'PENDING', 'What PENDING means and when it is set.'),
('ServerOps', 'TableName', 'Table', 'status_column', 'status_value', 2, 
    'COMPLETED', 'What COMPLETED means.');
```

For values shared across multiple columns:
```sql
('ServerOps', 'TableName', 'Table', 'col_a,col_b', 'status_value', 1, 
    'PENDING', 'Shared meaning for both columns.');
```

**Common Queries:**
```sql
INSERT INTO dbo.Object_Metadata 
    (schema_name, object_name, object_type, property_type, sort_order, title, description, content)
VALUES 
('ServerOps', 'TableName', 'Table', 'query', 1, 
    'Query Name',
    'Brief description of what this shows.',
    'SELECT col1, col2
FROM ServerOps.TableName
WHERE status = ''ACTIVE''
ORDER BY created_dttm DESC;');
```

**Relationship Notes:**
```sql
INSERT INTO dbo.Object_Metadata 
    (schema_name, object_name, object_type, property_type, sort_order, title, description, content)
VALUES 
('ServerOps', 'TableName', 'Table', 'relationship_note', 1, 
    'RelatedTableName', NULL,
    'How these two objects interact operationally.');
```

#### Sort Order for New Enrichment Rows

When adding enrichment rows to an object that already has content for that property type, use the MAX+1 pattern to determine the next sort_order:

```sql
-- Get next available sort_order for the property type on this object
DECLARE @nextSortOrder INT = (
    SELECT ISNULL(MAX(sort_order), 0) + 1
    FROM dbo.Object_Metadata
    WHERE schema_name = 'SchemaName'
      AND object_name = 'ObjectName'
      AND property_type = 'design_note'   -- match the property type being inserted
      AND is_active = 1
);
```

Sort order is scoped to `schema_name + object_name + property_type`. Design note sort_orders on one table are independent of query sort_orders on the same table. For bulk enrichment sessions where the full module is being documented at once, hardcoded sequential sort_orders (1, 2, 3...) are fine since you're writing all the rows. The MAX+1 pattern is for incremental additions to objects that already have enrichment content.

#### Updating Existing Descriptions

When an existing description is weak or incomplete, update rather than re-insert:

```sql
UPDATE dbo.Object_Metadata
SET content = 'Improved description text here.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE schema_name = 'ServerOps'
  AND object_name = 'ObjectName'
  AND column_name IS NULL          -- object-level
  AND property_type = 'description'
  AND is_active = 1;
```

For column-level descriptions, change `column_name IS NULL` to `column_name = 'column_name'`.

#### Enrichment Workflow

Enrichment is done per module, processing all object types together (tables, procs, triggers, scripts) to ensure consistent cross-references.

1. **Read all source files for the module** -- scripts (.ps1), procedures (.sql), and any existing documentation. Understand the full picture before writing any INSERTs.
2. **Script behavior analysis (mandatory for scripts):** Read the actual PowerShell code to capture conditional logic, error handling, AG awareness, and integration details that aren't visible from DDL or documentation alone.
3. **Check what already exists** -- run the preview query below to see current enrichment for the schema.
4. **Write INSERT statements for the whole module** -- all objects in one script. This ensures relationship_notes are consistent in both directions.
5. **Present as a single SQL script** with preview query at top and verification query at bottom.

**Preview query** (run before enriching -- shows existing enrichment for a schema):
```sql
SELECT object_name, property_type, column_name, sort_order, title, 
       LEFT(content, 80) AS content_preview
FROM dbo.Object_Metadata
WHERE schema_name = 'SchemaName'
  AND property_type NOT IN ('description', 'module', 'category')
  AND is_active = 1
ORDER BY object_name, property_type, sort_order;
```

**Verification query** (run after enriching -- confirms row counts):
```sql
SELECT property_type, COUNT(*) AS row_count
FROM dbo.Object_Metadata
WHERE schema_name = 'SchemaName'
  AND object_name = 'ObjectName'
  AND is_active = 1
GROUP BY property_type
ORDER BY property_type;
```

#### Procedures, Triggers, and Functions

These object types use the same INSERT patterns -- just change `object_type` to `'Procedure'`, `'Trigger'`, or `'Function'`. Enrichment is typically lighter: `data_flow` and `relationship_note` are the most useful. Triggers especially benefit from a `design_note` explaining what they protect or enforce.

#### Scripts (PowerShell .ps1 Files)

Scripts are the one object type with **no baseline rows from the bulk migration** and no system catalog safety net. See Section 3.5 for the mandatory baseline INSERT and naming conventions.

**Key differences from database objects:**

| Aspect | Database Objects | Scripts |
|--------|-----------------|---------|
| Baseline rows | Auto-populated from bulk migration | Must be manually inserted |
| object_type | Table, Procedure, Trigger, Function, View | Script |
| object_name | SQL object name (e.g., `Backup_FileTracking`) | Filename with extension (e.g., `Collect-BackupStatus.ps1`) |
| Column descriptions | Object_Metadata rows with column_name populated | Not applicable (scripts have no columns) |
| DDL in JSON export | Auto-generated from system catalog | Not applicable |
| Catalog presence | sys.tables, sys.procedures, etc. -- audit can detect missing baselines | None -- only Object_Metadata tracks scripts |

Scripts support the same enrichment property types as other objects. The most useful are `data_flow` (what systems it reads from and what tables it writes to), `design_note` (processing logic, AG awareness, preview mode behavior), and `relationship_note` (ProcessRegistry entry, GlobalConfig dependencies, tables read/written). `status_value` and `query` are not typically used for scripts -- status values belong on the tables the script writes to.

Scripts appear automatically on reference pages when they have Object_Metadata baselines (description, module, category). The `ddl-loader.js` dynamic category-based rendering (v3.0+) discovers them from the schema JSON without requiring explicit `data-objects` whitelists. Legacy pages may still use `data-objects` attributes as overrides, but new pages should rely on automatic discovery.

#### Regenerating JSON After Enrichment

After inserting or updating Object_Metadata rows, regenerate the JSON to see content on reference pages:

```powershell
# From the xFACts scripts directory -- processes all schemas:
.\Generate-DDLReference.ps1 -Execute
```

This regenerates all schema JSON files. The reference pages update automatically on the next page load.

#### What NOT To Do

- **No inline version references.** Don't put "new in v2.0" or "deprecated in 1.1" in any content. Documentation reflects current state only.
- **No System_Metadata entries for content changes.** Adding Object_Metadata rows is content population, not architectural change.
- **No DELETE statements.** Use `UPDATE ... SET is_active = 0` for content that should be removed.
- **Don't duplicate structural info.** Columns, types, constraints, indexes, and foreign keys come from the system catalog automatically. Object_Metadata provides the editorial layer on top.
- **Don't force enrichment.** Not every table needs design notes or relationship notes. Description + module + category + data_flow is perfectly fine for many objects.
- **Don't guess at field names.** Always check the actual source files (scripts, DDL) for column names, constraint names, and status values.

#### Audit Concept

Because Object_Metadata baselines are a manual step, they can be accidentally skipped during development. A periodic audit query should compare objects that exist in the system catalog (`sys.tables`, `sys.procedures`, etc.) against objects that have Object_Metadata baseline rows. Any object in the catalog without a corresponding Object_Metadata `description` row indicates a gap. This audit could be run manually during development reviews or automated as a scheduled check. The exact implementation is TBD, but the principle is: every object in the catalog should have Object_Metadata baselines.

---

## 3. PowerShell Standards

### 3.1 Script Header Format

The structure of a PowerShell file header -- the comment-based-help block, its required and forbidden keywords, where the component is declared, and where change history lives -- is defined by the PowerShell spec. Build headers to that spec; it is authoritative and the populators enforce it.

The platform-wide rule that spans this and every other file type: no hardcoded `Version: X.Y.Z` line in any header. The version lives in `dbo.System_Metadata` at the component level (see Section 2.6.2a). How a given file type expresses that -- the PowerShell spec uses a component declaration rather than a version line -- is the spec's to define.

### 3.2 Standard Initialization Block

All orchestrator-managed PowerShell scripts use the shared `Initialize-XFActsScript` function from `xFACts-OrchestratorFunctions.ps1` for initialization. This replaces the manual per-script initialization blocks that were used prior to the script standardization pass.

```powershell
# Dot-source shared functions, then initialize
. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"
Initialize-XFActsScript -ScriptName 'Collect-ServerHealth' -Execute:$Execute
```

`Initialize-XFActsScript` handles the following in a single call:
- SQL module import (SqlServer preferred, SQLPS fallback; exits the script if neither loads)
- Filesystem path restoration (SQLPS changes location to `SQLSERVER:\`)
- Application identity for DMV/XE attribution (sets the `xFACts <script-name>` application name used by the shared SQL helpers)
- Log file path setup for `Write-Log`
- Default connection parameters (server instance and database) for `Get-SqlData` / `Invoke-SqlNonQuery`
- Preview-mode guard message when `-Execute` is not specified

The function does not load GlobalConfig, ServerRegistry, or credentials -- scripts retrieve those themselves as needed (via `Get-SqlData` and `Get-ServiceCredentials`) after initialization.

**Ordering matters:** The dot-source of `xFACts-OrchestratorFunctions.ps1` must happen before calling `Initialize-XFActsScript`. The `$Execute` parameter must be declared in the script's `param()` block. `Initialize-XFActsScript` does not return a value -- it sets script-scope context variables that the shared functions read; there is no return to capture or guard on.

**Standalone scripts** that are not orchestrator-managed (utility scripts, one-time tools) may still use manual initialization if they don't need the full shared infrastructure. The key requirements remain: SQL module import, `-Execute` guard for anything that makes changes, and `-TrustServerCertificate` on all `Invoke-Sqlcmd` calls.

### 3.3 Connection Identity

All `Invoke-Sqlcmd` calls MUST include `-ApplicationName` to identify the calling script in SQL Server DMVs and Extended Events.

**Convention:** `xFACts <script-name-without-extension>`

```powershell
Invoke-Sqlcmd -ServerInstance $Instance -Database $DB -Query $Query `
    -ApplicationName "xFACts Collect-XEEvents" `
    -QueryTimeout 300 -ErrorAction Stop -TrustServerCertificate
```

This applies to every `Invoke-Sqlcmd` call in the script -- inline calls, calls inside helper functions, everything. Without this, connections appear as anonymous "Core .Net SqlClient Data Provider" in DMVs and XE data, making it impossible to attribute database load to specific scripts.

The Control Center uses ADO.NET connection strings with `Application Name=xFACts Control Center` -- handled centrally in the helpers module and does not require per-route changes.

### 3.4 Orchestrator Integration

**ProcessRegistry paths:** The `script_path` field uses filename only (e.g., `Send-OpenBatchSummary.ps1`), not a full path. The base directory is implied by the orchestrator engine's WorkingDirectory.

**Execution modes** are governed by the `execution_mode` field in `Orchestrator.ProcessRegistry`:
- **WAIT:** Orchestrator launches the script and waits for it to exit. Completion is handled by the orchestrator, which decrements the running count itself.
- **FIRE_AND_FORGET:** Orchestrator launches and moves on. The script calls `Complete-OrchestratorTask` when finished to report its status back and decrement the running count.

**Run mode** is a separate `ProcessRegistry` field (`run_mode`) controlling whether and how a process is activated, not how it executes: `0` = inactive (not launched), `1` = active orchestrated (launched on its schedule), `2` = on-demand (launched in response to Teams/Jira queue activity rather than a timer). Do not conflate `run_mode` with `execution_mode` -- a process has both.

**Engine events:** When a process completes, an HTTP POST is sent to the Control Center's internal engine-event endpoint (`Send-EngineEvent`, a fire-and-forget POST to the localhost CC port). The firing path differs by execution mode: in WAIT mode the orchestrator has already decremented the running count by the time the script's own callback runs, so the event fires from the orchestrator side; in FIRE_AND_FORGET mode the event fires from `Complete-OrchestratorTask`, but only when the last running instance finishes (the callback checks that the running count transitions to zero before pushing, so concurrent instances keep the engine card in its running state until all have completed). See Section 4.2 for the full communication flow.

### 3.5 Object_Metadata for Scripts

**PowerShell scripts have no SQL Server catalog presence.** Unlike tables and procedures, there are no system views and no automatic migration path for scripts. If the Object_Metadata baseline rows aren't created manually when the script is built, the script will be invisible to the documentation system -- it won't appear in the JSON export, won't render on the reference page, and won't be flagged by the audit query described in Section 2.9.

**When creating a new script, immediately create three baseline rows in `dbo.Object_Metadata`:**

```sql
INSERT INTO dbo.Object_Metadata 
    (schema_name, object_name, object_type, property_type, content)
VALUES 
    ('SchemaName', 'ScriptName.ps1', 'Script', 'description', 'What this script does'),
    ('SchemaName', 'ScriptName.ps1', 'Script', 'module',      'ModuleName'),
    ('SchemaName', 'ScriptName.ps1', 'Script', 'category',    'ComponentName');
```

**Naming convention:** `object_name` uses the full filename with `.ps1` extension (e.g., `Collect-BackupStatus.ps1`). This matches the `script_path` convention in ProcessRegistry (Section 3.4).

This is the one object type where there is no safety net. Database objects exist in the system catalog (`sys.tables`, `sys.procedures`) so their absence from Object_Metadata can be detected by an audit query. Scripts have nothing -- if you skip these rows, the script is undocumented until someone notices. Make it part of the same deployment as the script itself.

### 3.6 Shared Resources and Code Reuse

When the same code pattern exists in multiple scripts, it should live in a shared resource rather than being copied per script. This reduces maintenance burden and ensures consistent behavior when patterns need to change.

**Current shared resources:**

| Resource | Type | Purpose | Used By |
|----------|------|---------|---------|
| `xFACts-OrchestratorFunctions.ps1` | Dot-sourced file | Shared script infrastructure: standardized initialization, logging, SQL data access with application-name tagging, the orchestrator completion callback, engine-event reporting, credential retrieval, and Teams alert queuing. | All orchestrator-managed scripts (~10 scripts) |
| `xFACts-IndexFunctions.ps1` | Dot-sourced file | Schedule evaluation, window calculation, index selection, priority scoring. | Index maintenance scripts (Execute, Scan) + Admin API |
| `xFACts-CCShared.psm1` | PowerShell module | Control Center shared functions: database access, RBAC permission checks, dynamic navigation rendering, API caching, CRS5 and AG-aware data access, credential retrieval, and standardized response helpers. | Control Center (`Start-ControlCenter.ps1`) |
| `xFACts-AssetRegistryFunctions.ps1` | Dot-sourced file | Shared function library for the Asset_Registry parser pipeline: row construction, drift-code attachment, occurrence-index computation, registry loads, bulk insert, banner/file-header parsing, and the generic AST visitor walker. Per-language logic stays in each populator. | Asset_Registry populators (CSS, HTML, JS, PS) + the resolver |

The per-file function inventory is not enumerated here -- it goes stale the moment a function is added. For the specific functions a shared resource contains, query `dbo.Asset_Registry` (the catalog of every defined function, by file). A generated documentation surface for this is on the backlog; once built, this section will point to that file instead.

**Standard going forward:**

- **Before writing a new code block,** check the shared resources above. If the pattern already exists, use it.
- **If you write something reusable,** extract it into the appropriate shared resource immediately. Don't copy it into the next script that needs it.
- **If you find duplication during a modification,** create the shared resource and migrate the current script. Add a backlog item to migrate the remaining instances. Don't try to migrate everything at once -- do it incrementally as scripts are touched.
- **Dot-sourced files** (`.ps1`) are preferred for automation scripts that run standalone. **Modules** (`.psm1`) are preferred for the Control Center where `Import-Module` is called once at startup.

### 3.7 Error Handling and Credential Management

> **PENDING DOCUMENTATION.** The platform uses a two-tier encrypted credential management system in production today: a master passphrase (from GlobalConfig) decrypts a per-service passphrase, which in turn decrypts that service's credential values. Standalone scripts retrieve credentials via `Get-ServiceCredentials` (in `xFACts-OrchestratorFunctions.ps1`); Control Center routes use the equivalent in the CC shared module. Error-handling patterns across scripts are not yet cataloged. This section is a placeholder -- the full write-up of both the credential model and the error-handling conventions is pending a dedicated investigation (tracked on the backlog). Do not treat the brief description here as the complete specification.

---

## 4. Control Center: Architecture

### 4.1 Refresh Architecture

The Refresh Architecture defines how every Control Center page keeps its data current. The goal is consistency: every page follows the same model, so refresh behavior is predictable rather than reinvented per page.

#### Section Classification

Every data section on a page falls into one of four refresh modes, communicated to the user by a badge in the section header:

| Badge | Mode | Meaning | What triggers it |
|-------|------|---------|------------------|
| (event) | Event | Refreshes when an orchestrator process completes | A `PROCESS_COMPLETED` engine event for a process the page cares about |
| (live) | Live | Refreshes on a recurring timer | A GlobalConfig-driven polling interval |
| (action) | Action | Refreshes on user interaction | Button click, filter change, selection, etc. |
| (static) | Static | Loads once on page load | Initial page boot |

The mode is a property of the section's data, not the page: a single page commonly mixes all four -- a live-polling activity panel, an event-driven summary, an action-driven history view, a static reference table.

#### What a page provides

The shared CC infrastructure (the CC zone's shared files) does the heavy lifting. The WebSocket connection, the polling timer, the engine-event plumbing, the page-refresh control, and tab-resume and overnight-staleness handling all live in shared code -- not in each page. Every page renders the same header chrome through this shared infrastructure regardless of how it refreshes, so the platform looks and behaves consistently from page to page.

A page participates by declaring its own data and implementing the hooks relevant to it:

- **Engine processes** -- a page with engine cards declares the orchestrator processes it tracks; the shared infrastructure handles connection, card rendering, countdowns, and event delivery. A page with no engine cards still declares that explicitly (the empty declaration is required, not omitted) so the absence is intentional rather than an oversight.
- **Lifecycle hooks** -- a page implements only the hooks it needs (refresh-all, process-completed, tab-resumed, session-expired); the shared infrastructure invokes them at the right moments. A page with only static and action sections implements very little.
- **Live interval** -- a polling page has a GlobalConfig interval under the key pattern `refresh_<pagename>_seconds`; the shared infrastructure loads and applies it. A page that does not poll simply has no such entry -- it still renders identical chrome, it just has nothing on a timer.

These are not deviations from the model -- they are the model. A page that polls and a page that doesn't, a page with engine cards and one without, all share the same chrome and the same structure; they differ only in what data they declare. The variation is uniform, not exceptional.

The exact file structure for all of this -- the page boot function, the engine-processes declaration, the lifecycle hooks, and the action dispatch tables, including how each is written and where it lives in the file -- is defined by the JavaScript spec, with the chrome and shared CSS governed by the CSS spec. Build to those specs; this section describes the model, not the file format.

#### Refresh interval convention

Live-polling intervals live in `dbo.GlobalConfig` under the key pattern `refresh_<pagename>_seconds` (module `ControlCenter`, category `Refresh`). Storing the interval in config rather than hardcoding it lets refresh cadence be tuned per page without a code change.

### 4.2 Engine Events (WebSocket)

Engine indicators provide at-a-glance process health in the page header, answering "is the data on this page current?" without the user having to check anything. The indicator behavior -- connection, card rendering, countdowns, state escalation -- lives entirely in the CC zone's shared files; a page never implements engine-card behavior itself. How a page *declares* the engine processes it tracks, and how the engine-card markup and styles are structured, are defined by the JavaScript, HTML, and CSS specs. This section describes the communication architecture and the behavioral contract those shared files implement.

#### Communication Flow

```
Orchestrator Engine  --HTTP POST-->  Control Center (Pode)  --WebSocket-->  Browser Tabs
   (NSSM Service)                     /api/internal/engine-event             engine-events socket
                                      localhost-only, no auth
```

The orchestrator fires two event types: `PROCESS_STARTED` (after launch) and `PROCESS_COMPLETED` (after exit or callback). Events are JSON payloads carrying process identity (processId, processName, moduleName, taskId, timestamp) and, for completions, execution detail (status, durationMs, exitCode, outputSummary) plus the scheduling metadata the cards use for countdowns (interval, scheduled time, run mode).

The Control Center receives events on an internal POST route (localhost-only, no authentication -- the orchestrator and the CC run on the same host), stores the latest event per process in shared server state, and broadcasts to all connected browser tabs over a WebSocket. A browser receives current state on connect via a REST call, then live updates over the socket thereafter.

The push is fire-and-forget on the orchestrator side: if the Control Center is unreachable, the event is silently dropped. Engine operations must never depend on the Control Center being up (see the engine-event firing detail in Section 3.4).

#### Cold Start and Graceful Degradation

**Cold start:** If the Control Center has just restarted and holds no events in memory, cards show a disabled/waiting state and hydrate on the first event received for each process.

**Graceful degradation:** On WebSocket disconnect, the shared module auto-reconnects on a short interval and shows a subtle disconnect indicator. There is no polling fallback -- the connection either works or it visually signals that it doesn't.

#### Indicator Behavior

The engine card communicates process health through bar color and a countdown, escalating as a process becomes overdue:

| State | Color | Meaning |
|-------|-------|---------|
| Idle (healthy) | Green | Completed successfully; counting down to the next expected run |
| Running | Blue | Currently executing |
| Overdue | Yellow | Past the expected interval plus a short grace period |
| Critical | Red | Failed or timed out, or substantially past due |
| Disabled | Gray | Process is inactive (`run_mode = 0`) |

The countdown runs `M:SS` toward the next expected run; at zero it counts up with a `+` prefix to show how far overdue a process is. The card frame escalates in step with the bar so an overdue or failed process is visible at a glance. Clicking a card shows the last execution detail (time, duration, status, output summary) from the in-memory event, with no additional server call. The literal color values, the grace-period length, and the escalation thresholds are properties of the shared chrome and live with the CSS spec's design tokens -- this table describes what the states *mean*, not their exact values.

### 4.3 API Patterns

The structure of an API route file -- the `Add-PodeRoute` registration, the `-Authentication 'ADLogin'` requirement, the `Test-ActionEndpoint` guard as the first statement, the `Write-PodeJsonResponse` close, and how SQL is embedded and parameterized -- is defined by the PowerShell spec. Build API routes to that spec.

API paths follow the convention `/api/{module}/{endpoint}` (e.g., `/api/server-health/kill-session`). RBAC enforcement on these endpoints is covered in Section 4.4.

**Data access -- choosing the right helper.** The one architectural decision a route author makes that the spec does not dictate is *which* shared data-access function to call, and that is determined by which database the query targets. The CC shared module provides a helper per target:

| Target database | Read | Write / other |
|-----------------|------|---------------|
| xFACts (the platform's own AG database) | `Invoke-XFActsQuery` | `Invoke-XFActsNonQuery`, `Invoke-XFActsProc` |
| Any other AG-hosted database (via the listener) | `Invoke-AGReadQuery` | -- |
| CRS5 / Debt Manager | `Invoke-CRS5ReadQuery` | `Invoke-CRS5WriteQuery` |

Use the helper that matches the target rather than opening connections directly -- the helpers centralize application-name tagging, connection handling, and AG-aware routing. For results that are expensive to compute and tolerate brief staleness, wrap the call in the caching helper (`Get-CachedResult`) rather than caching ad hoc. The authoritative, always-current list of these helpers and their signatures is in `dbo.Asset_Registry` (and, once built, the generated shared-function reference noted in Section 3.6) -- not enumerated here, where it would go stale. If that generated reference ends up carrying per-helper purpose detail, this table is a candidate to be replaced by a pointer to it.

### 4.4 Pode Framework, RBAC, and Dynamic Navigation

The Control Center is built on the Pode PowerShell web framework. All routes, APIs, authentication, and shared state are configured through Pode primitives. RBAC permission checks and dynamic navigation are implemented as helper functions in `xFACts-CCShared.psm1`, available to every route at runtime.

#### Pode Startup and Module Loading

`Start-ControlCenter.ps1` is the entry point. It:

1. Imports `xFACts-CCShared.psm1` as a Pode module -- making all exported functions available across all Pode runspaces (routes, middleware, WebSocket handlers).
2. Initializes Pode shared state (`ApiCache`, `ApiCacheConfig`) and named lockables for thread-safe access.
3. Configures ADLogin authentication for protected routes.
4. Discovers and dot-sources every route file in `scripts/routes/`. Both page routes (`<Name>.ps1`) and API routes (`<Name>-API.ps1`) live in this single directory -- there is no separate API subdirectory. Each file calls `Add-PodeRoute` for its route registration.
5. Starts the Pode server on port 8085 with WebSocket support.

When adding a new route or API file, simply place it in `scripts/routes/` -- the discovery loop picks it up automatically. CC restart is required for the new file to load.

#### RBAC Permission Checks

Every page route MUST perform a page-level access check before rendering content, and every API route MUST perform an action-level check as its first statement. The structural form of these checks -- where the call goes in the route scriptblock and how the route is shaped around it -- is defined by the PowerShell spec (page routes call `Get-UserAccess` first and close with `Write-PodeHtmlResponse`; API routes call `Test-ActionEndpoint` first and close with `Write-PodeJsonResponse`). What matters at the architecture level is the logic those calls perform:

- **`Get-UserAccess`** resolves the user's effective tier for the page route and returns an access decision with full context. A page that fails the check renders the styled 403 page (`Get-AccessDeniedHtml`) instead of its content.
- **`Test-ActionEndpoint`** looks up the endpoint in `RBAC_ActionRegistry`, runs the full permission check (USER DENY -> ROLE DENY -> USER ALLOW -> ROLE ALLOW -> tier fallback), and sends a 403 JSON response automatically if denied. It is **fail-open for unregistered endpoints** -- an endpoint with no `RBAC_ActionRegistry` row passes through, so registration takes effect the moment a row is added without touching the route code.

**Helper function reference:**

| Function | Purpose | Returns |
|---|---|---|
| `Get-UserAccess` | Page-level access check with audit logging | Hashtable: `HasAccess`, `Tier`, `Roles`, `RoleNames`, `DepartmentScopes`, `Username`, `DisplayName`, `IsDeptOnly`, `EnforcementMode` |
| `Get-UserContext` | Lightweight user identity for UI rendering (no audit log entries) | Hashtable: `Username`, `DisplayName`, `Roles`, `RoleNames`, `DepartmentScopes`, `UserDepartments`, `IsDeptOnly`, `IsAdmin`, `HasPlatformAccess`, `EnforcementMode` |
| `Test-ActionPermission` | Action-level permission check (call manually with explicit page route + action name + required tier) | Boolean |
| `Test-ActionEndpoint` | Action-level permission check via ActionRegistry lookup (call at top of API routes) | Boolean (sends 403 response on denial) |
| `Get-AccessDeniedHtml` | Returns styled 403 page HTML | String |
| `Get-ActionDeniedResponse` | Returns standardized 403 JSON | PSCustomObject |

All RBAC functions read from an in-memory cache in the shared module, which refreshes from the database every 5 minutes (or immediately on CC restart). This avoids per-request database queries while keeping permissions current.

#### Dynamic Navigation

The horizontal nav bar at the top of every page and the Home page tile grid are both rendered dynamically based on the user's permissions. Source-of-truth data lives in two tables:

- **`dbo.RBAC_NavSection`** -- Top-level section groupings (Platform, Departmental Pages, Tools, Administration). Each section has a sort order and a CSS accent class.
- **`dbo.RBAC_NavRegistry`** -- Master inventory of CC pages. Each row joins to `RBAC_PermissionMapping` via `page_route` and contains nav metadata: nav label, display title, description, section grouping, sort order within section, optional doc page link, and visibility flags.

Both tables are loaded into the RBAC cache on the same 5-minute refresh cycle as roles and permissions.

**Helper functions for nav rendering:**

| Function | Purpose | Returns |
|---|---|---|
| `Get-NavBarHtml -UserContext $ctx -CurrentPageRoute '/X'` | Renders the complete `<nav>` HTML block for a user | String (HTML) |
| `Get-HomePageSections -UserContext $ctx` | Returns structured section + page data for Home tile rendering | Array of section hashtables |

Both functions filter pages by user permission (silently -- no audit log entries), apply section grouping with separators, attach the `accent_class` from `RBAC_NavSection` to each link/tile, and append the admin gear icon for admin users. Empty sections are omitted entirely from the output.

**Visibility flags on `RBAC_NavRegistry`:**

| Flag | Meaning |
|---|---|
| `is_active` | Soft-delete. 0 = retired or future page, fully hidden from all rendering |
| `show_in_nav` | Appears in the horizontal nav bar |
| `show_on_home` | Appears as a tile on the Home page |

Common combinations:

| Use case | is_active | show_in_nav | show_on_home |
|---|---|---|---|
| Standard CC page | 1 | 1 | 1 |
| Tile-only utility (e.g., Client Portal) | 1 | 0 | 1 |
| Direct-access only (e.g., `/bdl-import`) | 1 | 0 | 0 |
| Admin/wildcard pages (`/admin`, `/platform-monitoring`) | 1 | 0 | 0 |
| Future placeholder page | 0 | 1 | 1 |

**Special case -- Home as universal first link:** The root route `/` is intentionally NOT stored in `RBAC_NavRegistry`. Home is handled as the universal first link in the nav bar by `Get-NavBarHtml` -- every nav bar starts with a Home link regardless of section. This keeps the registry as a clean catalog of destination pages and avoids special-case sort_order handling.

**Special case -- wildcard-permission pages:** Admin-only pages (`/admin`, `/platform-monitoring`) have entries in `RBAC_NavRegistry` for inventory completeness but no explicit rows in `RBAC_PermissionMapping`. They rely on the Admin role's wildcard `*` permission. The coverage gap-check query flags these as false positives -- accepted known behavior.

**Section accent classes.** Each nav section carries an accent color that visually pairs the nav link with the page's H1 color. The accent is expressed as a CSS class on the emitted nav link, defined in `cc-shared.css` (the CHROME nav-bar section):

| section_key | Emitted class | Visual effect |
|---|---|---|
| platform | `cc-nav-section-platform` | Blue accent on hover and active state (the default) |
| departmental | `cc-nav-section-departmental` | Yellow on hover and active |
| tools | `cc-nav-section-tools` | Soft blue on hover and active |
| admin | `cc-nav-section-admin` | `display: none` (defensive -- admin pages are reached via the gear icon, never rendered as nav links) |

There is one subtlety worth understanding. The `accent_class` value stored in `dbo.RBAC_NavSection` is **unprefixed** (e.g., `nav-section-platform`). `Get-NavBarHtml` prepends `cc-` at emission time, so the rendered HTML carries the prefixed chrome class (`cc-nav-section-platform`) while the database row stays unchanged. This was deliberate during the chrome-prefix migration: the emitted markup conforms to the CSS spec's `cc` chrome prefix without requiring a data migration of the `RBAC_NavSection` rows. When reading the database you will see the bare value; when inspecting the page source you will see the `cc-` form.

The active (current-page) nav link is marked with a `cc-active` state token applied alongside the section class, styled via the compound rule `.cc-nav-link.cc-active` (and the per-section compounds). The same accent grouping is intended to apply to the Home page tiles as well, so the nav bar and the Home grid share one visual scheme; the exact chrome classes for the tile surface follow the same `cc-` chrome model once a page is built to spec.

#### RBAC Configuration

Two GlobalConfig settings drive RBAC behavior:

| Setting | Purpose | Values |
|---|---|---|
| `ControlCenter.RBAC.rbac_enforcement_mode` | Controls whether permission failures actually deny access | `disabled`, `audit`, `enforce` |
| `ControlCenter.RBAC.rbac_audit_verbosity` | Controls audit log volume | `denials_only`, `all` |

In `audit` mode, denials are logged as `WOULD_DENY` events but access is granted -- used for safe pre-flip analysis. In `enforce` mode, denials block access and log as `DENIED`. In `disabled` mode, all RBAC checks pass (effectively no RBAC).

The `rbac_audit_verbosity` setting controls whether successful access events are logged. `denials_only` logs only denials and would-denials. `all` logs every check including ALLOWED events -- useful during enforcement rollout, expensive long-term.

#### Audit Logging

`dbo.RBAC_AuditLog` captures every permission decision. Schema includes event type (`ACCESS_DENIED`, `ACCESS_ALLOWED`, `ACTION_DENIED`, `ACTION_ALLOWED`, `ACCESS_AUDIT`, etc.), username, AD groups, resolved roles, page route, action name, required tier, user tier, result (`ALLOWED`, `DENIED`, `WOULD_DENY`), detail message, client IP.

Login events (`LOGIN_SUCCESS`, `LOGIN_FAILURE`) are also written to this table -- they're independent of page/action permission checks.

The `Write-RBACAuditLog` function in `xFACts-CCShared.psm1` handles all writes. It respects the verbosity setting silently -- callers don't need to check verbosity before calling.

**Important: nav rendering does NOT trigger audit log entries.** `Get-NavBarHtml` and `Get-HomePageSections` use `Get-UserPageTier` for filtering, which is silent. Audit logging happens only in `Get-UserAccess` and `Test-ActionPermission`.

---

### 4.5 Adding a New Control Center Page

When adding a new page to the Control Center, follow this sequence to ensure proper integration with RBAC, dynamic nav, and the documentation system. Skip any step at your peril -- the system depends on these registrations being complete.

#### Decision points before starting

- Which **section** does the page belong to? `platform`, `departmental`, `tools`, or `admin`?
- Should it appear in the **horizontal nav bar**? (`show_in_nav`)
- Should it appear as a **tile on the Home page**? (`show_on_home`)
- Does it have (or will it have) a **documentation page**? (`doc_page_id`)
- Which **roles** should have access, and at what **tier** (`view`, `operate`, `admin`)?

#### Step-by-step

**1a. Insert into `dbo.RBAC_NavRegistry`.**

```sql
INSERT INTO dbo.RBAC_NavRegistry 
    (page_route, nav_label, display_title, description, section_key, sort_order, 
     doc_page_id, show_in_nav, show_on_home, is_active)
VALUES
    ('/your-route', 'Short Label', 'Display Title', 
     'Descriptive text used as page subtitle and Home tile description.',
     'platform', 120,        -- next sort_order in section, increments of 10
     'yourdocpage',          -- or NULL if no doc page yet
     1, 1, 1);
```

Choose `sort_order` carefully -- it controls where the page appears within its section. Use increments of 10 from the previous highest value in the section. This leaves room to insert pages between existing ones without renumbering.

**1b. Determine the page's chrome.**

By default, the page inherits standard chrome from the CC zone's shared files (`cc-shared.css` and `cc-shared.js`). The route file is responsible for:

- Setting the page's section accent by tagging the body with the section class (driven by the `section_key` from the `RBAC_NavRegistry` row you just inserted), so the H1 and accent color follow the section automatically.
- Including the standard header structure (header bar, the always-present refresh info row, and the engine card row if the page has engine cards) per the chrome contract in Section 5, built to the HTML and CSS specs.
- Keeping the page-specific CSS file to content rules only -- it must not redefine chrome. (The CSS spec enforces this: chrome classes live in the shell file, and page files carry only their own prefixed classes.)

The structure of the route file itself -- the header, the section banners, the `Add-PodeRoute` shape, the RBAC check placement, and how the page emits its HTML -- is defined by the PowerShell spec, with the markup it emits governed by the HTML spec and the styles by the CSS spec. Build to those specs rather than copying an existing page; a named page can drift or be mid-refactor, whereas the specs are the authority.

**2. Insert into `dbo.RBAC_PermissionMapping`** for each role that should have access:

```sql
-- Standard pattern: most platform pages accessible to all standard users
INSERT INTO dbo.RBAC_PermissionMapping (role_id, page_route, permission_tier) VALUES
    (2, '/your-route', 'operate'),  -- PowerUser
    (3, '/your-route', 'operate'),  -- StandardUser
    (4, '/your-route', 'view');     -- ReadOnly

-- Admin gets access via wildcard '*' permission, no explicit row needed.

-- Wildcard-permission pages (admin-only): no PermissionMapping rows at all.
-- They rely entirely on the Admin role's '*' wildcard.
```

**3. Create the route and API files** in `scripts/routes/`. The page route is `<Name>.ps1`; its API counterpart is `<Name>-API.ps1` in the same directory. Both are built to the PowerShell spec -- including the file header, section banners, the `-Authentication 'ADLogin'` requirement, the `Get-UserAccess`-first / `Write-PodeHtmlResponse`-last shape for the page route, and the `Test-ActionEndpoint`-first / `Write-PodeJsonResponse`-last shape for the API route. The route emits its page HTML as a here-string that links the page's own CSS/JS plus the CC-zone shared files, and renders the nav via `Get-NavBarHtml` rather than hardcoding it.

**Critical rules:**
- Do NOT hardcode the nav HTML -- let `Get-NavBarHtml` handle it.
- Do NOT manually emit the admin gear -- `Get-NavBarHtml` includes it when appropriate.
- Do NOT put chrome rules (nav bar, header, refresh info, engine cards) in the page's CSS file -- those live in the shell file (`cc-shared.css`) as the single source of truth; the page CSS carries only its own content classes.
- The page's H1 documentation link should match the `doc_page_id` value from the NavRegistry row.

**4. Object_Registry entry.** Add a row in `dbo.Object_Registry` under the appropriate component:

```sql
INSERT INTO dbo.Object_Registry 
    (module_name, component_name, object_name, object_category, object_type, object_path, description)
VALUES 
    ('YourModule', 'YourModule.YourComponent', 'YourPage.ps1', 'WebAsset', 'Route',
     'E:\xFACts-ControlCenter\scripts\routes\YourPage.ps1', 
     'Brief description of the page.');
```

Repeat for the API file (`object_type = 'API'`), CSS file (`object_type = 'CSS'`), and JS file (`object_type = 'JavaScript'`) under the same component.

**5. Restart Control Center** to pick up:
- The new route registration (Pode loads route files at startup)
- The new RBACCache data (pulls fresh from NavRegistry and PermissionMapping)

After restart, the page appears in the nav bar and Home tiles automatically for users who have permission.

**6. End-of-session version bump.** Per Section 2.6.7, record what changed in the parent component's `dbo.System_Metadata`. Include the new route file, API file, CSS, JS, and NavRegistry/PermissionMapping rows in the description.

#### Verification checklist

After deploying:

- [ ] Navigate to the route -- page loads correctly
- [ ] Nav bar includes the new page in the right section, with the right label
- [ ] Home page shows the new tile in the right section (if `show_on_home = 1`)
- [ ] Section accent color applies on hover and active state
- [ ] Active page highlighting works when on the new page
- [ ] Users without permission get a 403 Access Denied page
- [ ] Browser DevTools console shows no errors
- [ ] Coverage gap-check query returns clean (no orphans for this page)

#### Coverage gap-check query

Run this query periodically (and after adding new pages) to verify NavRegistry and PermissionMapping are in sync:

```sql
WITH nav_pages AS (
    SELECT DISTINCT page_route FROM dbo.RBAC_NavRegistry WHERE is_active = 1
),
perm_pages AS (
    SELECT DISTINCT page_route 
    FROM dbo.RBAC_PermissionMapping 
    WHERE is_active = 1 
      AND page_route NOT IN ('*', '/')
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
```

Expected baseline result: `/admin` and `/platform-monitoring` only -- these are wildcard-permission pages and the false positive is acceptable. Any other rows indicate a gap to investigate.

---

## 5. Control Center: Visual Standards

### 5.1 Page Chrome

Every Control Center page shares one common chrome structure -- the fixed nav bar, the header bar (page title, optional center controls, refresh-info row), the engine card row where applicable, and the body container. None of this is built or styled per page: it is provided by the CC zone's shared files (`cc-shared.css` for the styles, `cc-shared.js` for behavior) and rendered into each page by the shared helpers (the nav bar via `Get-NavBarHtml` -- see Section 4.4). The refresh-info row -- the "Live" indicator and "Updated:" timestamp -- is part of that chrome and appears on every page identically; a page that does not poll simply shows it without the live dot. A page's job is to supply its own content and declare its data (engine processes, refresh interval, lifecycle hooks per Section 4.1); it does not redefine chrome. The structure of the chrome markup and the literal style values (sizes, colors, spacing) are governed by the HTML and CSS specs, which also enforce that page CSS files carry only their own content classes and never restyle chrome.

### 5.2 Typography

Two font families are used across the platform: **Segoe UI** for essentially everything -- labels, values, headings, body text, table content -- and **Consolas** (monospace) reserved for code identifiers: SQL query text, flow/system identifiers, and similar. Consolas is not used for ordinary data display (counts, timestamps, numeric values); those are Segoe UI like the rest of the UI. A consistent size and weight hierarchy is applied through the CSS spec's font and size tokens rather than per-page literals -- consult the tokens for the actual values.

### 5.3 Color and Status Semantics

The platform uses a dark theme, and color carries meaning. The house pattern for status is **colored text on a faint matching background tint** rather than saturated fills. The semantic mapping is consistent across the platform:

| Meaning | Color family |
|---------|--------------|
| Success / healthy | Green / teal |
| In progress / info | Blue |
| Warning | Yellow |
| Error / failed | Red / orange |
| Crisis | Dark red |
| Validated / special | Purple |
| Dimmed / inactive | Gray |

The literal color values (and the background-tint opacities) live in the CSS spec's color tokens; this table is the *meaning*, not the values. When a value is needed, use the matching token rather than a hex literal -- the CSS spec treats a hex literal that duplicates a token's value and purpose as drift.

### 5.4 Status Indicators and Badges

The platform's preferred status indicator is a small **text pill** -- an uppercase, rounded label carrying the status word (e.g., SUCCESS, RUNNING, WARNING). Text pills read clearly and avoid the ambiguity of symbol-only indicators, so they are the default choice for new work. (This is a preference, not an absolute -- round status dots, and the occasional symbol, exist on some pages where they suit the context.)

**Status vocabulary follows the entity type** -- use the words that fit the thing being described rather than mixing vocabularies: individual executions are PENDING / RUNNING / SUCCESS / FAILED; flow containers are IN PROGRESS / COMPLETE / NOT DETECTED; validation states have their own set (VALIDATED, PARTIAL, CRITICAL, etc.). The point is consistency within an entity type -- don't label a flow SUCCESS when flows COMPLETE.

**Identifier badges** (flow codes, system identifiers) are intentionally distinct from status pills: they carry a border and use the monospace font, which makes them feel tangible and selectable. The practical distinction worth preserving -- identifier badges have borders, status pills generally don't -- keeps the two kinds of label from visually blurring together. Exact styling (sizes, colors, borders) is defined by the CSS spec tokens and chrome classes.

### 5.5 Visual Calm

A guiding principle for dashboards: **color means "look at me"; the absence of color means "all clear."** A healthy dashboard should be visually quiet, with color reserved for states that want attention -- warning, critical, crisis -- typically applied as a full card frame with a faint matching background tint rather than a single accent edge. This is design intent, not a hard rule: some pages legitimately use a healthy-state color because the status itself is the primary information (build completion, agent health), and that's a reasonable judgment call per page. The aim is a calm baseline that makes genuine problems jump out, not a prohibition on ever showing a healthy color.

### 5.6 Refresh Mode Badges

Each data section can carry a small badge indicating how it refreshes -- event, live, action, or static. The four modes and their meanings are described in Section 4.1; the badge markup and styling are chrome, defined by the HTML and CSS specs.

### 5.7 Shared vs. Page-Specific Styling

The governing principle: shared visual patterns and behaviors belong in the CC zone's shared files; page-specific files carry only what is unique to that page. A page's CSS holds its own content layout and components; it does not restyle chrome (nav bar, header, refresh row, engine cards) -- the CSS spec enforces this by keeping chrome classes in the shell file and page classes under the page's own prefix. A page's JS declares its own data and behavior and routes actions through the shared dispatch model. When a pattern recurs across pages, it is a candidate to move into the shared files; the file-structure rules for all of this are in the CSS and JavaScript specs.

Shared dialog behavior (alerts, confirmations) and other cross-page UI behaviors are provided by the CC zone's shared JS rather than reimplemented per page, and native browser dialogs (`alert`, `confirm`, `prompt`) are avoided in favor of the shared styled equivalents.

### 5.8 Viewport Containment

The preferred page layout keeps the entire page within the viewport at all times -- the nav bar and page header stay in view, and content that exceeds the available height scrolls *within its own container* rather than scrolling the browser window. The goal is that a user never has to scroll the nav and header off the top of the screen to reach content.

This is a preferred pattern, not yet universal: some pages establish a viewport-bounded content container that scrolls internally, while others let their content area grow unbounded and produce a browser-level page scroll (which pushes the nav and header out of view when content is long -- the outcome this pattern exists to avoid). New pages should follow the contained approach. The mechanism -- the viewport-height body constraint and the internal-scroll content container -- is chrome, implemented in the CC zone's shared files and governed by the CSS spec; a page participates by keeping its content within that container rather than overriding the constraint.

---

## 6. Documentation Standards

### 6.1 Documentation Architecture

All xFACts documentation is authored and maintained as HTML pages hosted within the Control Center (`E:\xFACts-ControlCenter\public\docs\`). The documentation is organized into the page types below. For platform pages, the standard set is four tiers -- Narrative, Architecture, CC Guide, and Reference -- authored together so a platform module has the full progression from plain-language overview through to nuts-and-bolts. This four-tier expectation applies to platform pages specifically; departmental, tools, and admin-level pages are documented more selectively (often just the tiers that earn their keep for that page), and the standalone Guide type is filesystem-discovered rather than tied to a module at all. The tiers carry distinct audiences and content levels:

| Tier | Page Type | Primary Audience | Content Level |
|------|-----------|-----------------|---------------|
| **Narrative** | `{module}.html` | Everyone: executives, department managers, team members, developers | What it does, why it matters, how it fits. No table names, no column names, no code blocks. Accessible, conversational, brief. Humor welcome. |
| **Architecture** | `{module}-arch.html` | Development team + curious readers from the narrative audience | How it works technically. Data flows, status machines, scheduling logic, ERDs, integration details. Written to be engaging -- not a cure for insomnia. |
| **Reference** | `{module}-ref.html` | Development team | Nuts and bolts. Auto-generated from schema JSON files via `ddl-loader.js`. Full DDL, field definitions, Object_Metadata content, operational queries. |
| **CC Guide** | `{pageId}-cc.html` | Everyone who uses the Control Center page | Interactive visual walkthrough of the corresponding Control Center page. Mockup diagram with numbered callout markers, flip-card key to UI elements, section-by-section feature guide. Written for understanding what you're looking at, not how it's built. |
| **Guide** | `pages/guides/{name}.html` | Target audience varies per guide | Standalone walkthrough or tutorial for a specific tool or workflow. Visual mockups, step-by-step instructions, tips and troubleshooting. Not tied to Component_Registry -- auto-discovered by the publisher from the filesystem. |

**The narrative page is the entry point** for reading about a module. Every module's narrative page links to its architecture and reference pages. A Control Center dashboard page, however, links via its page title to its corresponding **CC Guide** page (opening in a new tab), not the narrative -- the CC Guide is the visual walkthrough of what's actually on that screen, so it's the most useful destination for someone looking at the live page and wanting to understand what they're seeing. The Hub page (`index.html`) provides navigation to all modules.

**Voice guidelines:**

- **Narrative pages:** Write like you're explaining the system to a smart person who has never seen SQL Server. The President, the CEO, the department manager who says "ess-queue-ell" -- they should all be able to read this and walk away understanding what the thing does. Think "stand-up comedian with tech knowledge giving a TED Talk." Straight to the point, with laughter as a bonus.
- **Architecture pages:** All the technical detail the narrative page deliberately omits, but written in a way that keeps you reading. Use tech-tips for non-obvious details, info tables for structured comparisons, and diagram placeholders for visual flows. The audience is anyone who read the narrative page and said "cool, I want to know more."
- **Reference pages:** Auto-generated -- no voice needed. Content quality depends entirely on Object_Metadata enrichment (Section 2.9).

**Voice -- Do This:**

- **Explain the "why" before the "what."** "SQL Server replication is one of those things that works beautifully until it doesn't" tells you more about why a module exists than any feature list.
- **Use analogies people actually get.** Mo the orchestrator. The TV guide metaphor. "Like window shopping for database metrics." These land because they're specific.
- **Name things.** Mo is more memorable than "the orchestrator procedure." The zombie killer is more memorable than "the idle session termination feature."
- **Acknowledge the reality.** "The data warehouse may be a 20-year-old architectural marvel held together by views, functions, and sheer determination." People trust documentation that's honest.
- **Include the team's personality.** "We don't anger the gods unnecessarily." "Because we're not monsters." This is what makes it a Frost Arnett document, not a generic technical manual.

**Voice -- Don't Do This:**

- **Don't force humor.** If a section is naturally dry (DDL reference, configuration tables), let it be dry. The humor makes the narrative sections memorable -- it doesn't need to be everywhere.
- **Don't repeat yourself.** If Teams alerting is explained on the Teams page, other modules reference it -- they don't re-explain it.
- **Don't bury the practical stuff.** Someone troubleshooting at 2 AM needs to find the answer fast. The conversational tone is the wrapper, not the obstacle.
- **Don't over-document stable things.** A table that hasn't changed in months doesn't need three paragraphs. A sentence and a DDL expandable section is fine.

**Use of specific references:** Avoid documenting specific configurable values (polling intervals, cycle times, timeout durations, start times, f&f vs wait execution types) in narrative or architecture pages. Use generic language like "configurable schedule", "on each cycle." "runs in a configurable mode", etc. Storytelling examples with illustrative times are acceptable. This keeps documentation current without requiring updates when configuration values change.

**File structure:** See Section 6.1.1 for the complete documentation file structure, including all page type subfolders and the data/JSON layer.

**Module naming:** Each module uses a short prefix for file naming (e.g., `serverhealth`, `batchops`, `jobflow`, `controlcenter`). New modules should follow the same pattern -- short, descriptive, hyphenated if needed. The current set of page identifiers is visible in `doc-registry.json` (generated by the DDL pipeline) or by querying `SELECT DISTINCT doc_page_id FROM dbo.Component_Registry WHERE doc_page_id IS NOT NULL`.

**Documentation page inventory:** The current inventory of documentation pages -- which modules have narrative, architecture, reference, and CC guide pages -- is driven dynamically by Component_Registry metadata. Refer to `xFACts_Platform_Registry.md` in the project files for the current Component_Registry export showing `doc_page_id`, `doc_json_schema`, `doc_sort_order`, and `doc_cc_slug` for every component. The `doc-registry.json` file (regenerated by the DDL pipeline) is the runtime representation consumed by `nav.js` and the publisher.

### 6.1.0 Documentation Review Checklist (End of Session)

When a session introduces architectural changes, new features, or behavioral modifications to any module, review these documentation targets before closing:

**Architecture page (`*-arch.html`):** Process flow descriptions, stage diagrams, design decision callouts, "How Everything Connects" tables, troubleshooting guidance. Update when scripts gain new steps, data flow changes, new integrations are added, or existing behavior is modified. This page describes *how* things work -- if the "how" changed, the arch page needs updating.

**Control Center guide page (`*-cc.html`):** Section descriptions, card behavior, interactive features, refresh behavior, callout boxes. Update when CC pages gain new click actions, slideouts, modals, new sections, or when existing card content changes meaning. This page describes *what the user sees* -- if the UI changed, the CC guide needs updating.

**Object_Metadata (SQL INSERTs/UPDATEs):** Column descriptions for new columns, `design_note` entries for new architectural decisions, `status_value` updates when status meanings change, `data_flow` updates when scripts read/write differently. These drive the auto-generated reference pages (`*-ref.html`). Reference pages are never edited directly -- all content comes from Object_Metadata.

**Narrative page (`*.html`):** Rarely needs changes. Written at a high level ("what does this module do and why"). Only update if the module's fundamental purpose, scope, or operational model changes -- not for implementation details.

**Quick reference -- what goes where:**

| Change Type | Arch Page | CC Guide | Object_Metadata |
|-------------|:---------:|:--------:|:---------------:|
| New script step or processing logic | [x] | | |
| New or modified design decision | [x] | | [x] (`design_note`) |
| New table column | | | [x] (`description`) |
| Changed status value meaning | | | [x] (`status_value`) |
| New CC interactive feature (modal, slideout, click) | | [x] | |
| Changed CC card content or behavior | | [x] | |
| New integration or dependency | [x] | | [x] (`relationship_note`) |
| New GlobalConfig setting | [x] (if affects flow) | | |
| Script data_flow change | | | [x] (`data_flow`) |

### 6.1.1 Documentation Registry

The documentation site's navigation, page discovery, and publishing pipeline are all driven by metadata columns on `dbo.Component_Registry`. These columns are the single source of truth for which documentation pages exist, what they're called, how they're ordered in the nav, and which JSON data feeds their reference pages.

#### Component_Registry Documentation Columns

Seven `doc_*` columns on `dbo.Component_Registry` control documentation behavior. A component with `doc_page_id = NULL` has no documentation page and is invisible to the documentation system.

| Column | Type | Purpose |
|--------|------|---------|
| `doc_page_id` | `VARCHAR(50)` | The page identifier. Drives all filename conventions. Multiple components can share the same `doc_page_id` to appear as sections on one page (e.g., Engine Room has three components all pointing to `engine-room`). |
| `doc_title` | `VARCHAR(100)` | Display title for the page in navigation. Only the **primary row** (the one with `doc_sort_order` populated) needs this set for top-level nav. For CC guide sub-pages (rows with `doc_cc_slug` populated), this provides the nav label for that specific guide page. |
| `doc_sort_order` | `INT` | Position in the top-level navigation. Only one row per `doc_page_id` should have this set -- that row becomes the **primary row** for the page. `0` identifies the hub/index page. `NULL` means this row is a section contributor, not the nav entry. |
| `doc_section_order` | `INT` | Order of this component's section within a multi-component page. Used by reference pages to sequence DDL sections. |
| `doc_json_schema` | `VARCHAR(50)` | Which database schema's JSON file to load for reference page DDL rendering (e.g., `ServerOps`, `BatchOps`). **Dual purpose:** this field also controls whether the Confluence publisher generates a reference page. The publisher only creates reference content when at least one section under the `doc_page_id` has `doc_json_schema` populated. If no section has it set, the reference page will render correctly in the HTML documentation site (via the `data-schema` attribute on the HTML element) but will **not** be published to Confluence. |
| `doc_json_categories` | `VARCHAR(200)` | Comma-separated category filter for reference pages that share a schema JSON file but only show a subset of objects (e.g., Server Health uses schema `ServerOps` with categories `Activity,Disk` to exclude Backup, Index, and Replication objects). |
| `doc_cc_slug` | `VARCHAR(50)` | **Named CC guide page identifier.** When populated, this component has a dedicated CC guide page at `{pageId}-cc-{slug}.html` in the `cc/` subfolder. The `doc_title` on this same row provides the nav label for this guide page. When NULL, the standard single-file convention `{pageId}-cc.html` applies. See **Multiple CC Guide Pages** below. |

#### Primary Row vs. Section Rows

When multiple components share a `doc_page_id`, exactly one row should have `doc_sort_order` populated -- this is the **primary row**. It determines the page's position in the nav and provides the top-level `title` in `doc-registry.json`. All other rows with the same `doc_page_id` are **section rows** -- they contribute to the page's `sections` array in the registry but don't affect navigation ordering.

Example: The Engine Room page (`doc_page_id = 'engine-room'`):

| component_name | doc_page_id | doc_title | doc_sort_order | doc_section_order |
|---|---|---|---|---|
| Engine.SharedInfrastructure | engine-room | The Engine Room | 10 | 1 |
| Engine.Orchestrator | engine-room | *(NULL)* | *(NULL)* | 2 |
| Engine.RBAC | engine-room | *(NULL)* | *(NULL)* | 3 |

`Engine.SharedInfrastructure` is the primary row (has `doc_sort_order = 10`). The other two are section rows that contribute DDL content to the reference page in order.

#### doc-registry.json

`Generate-DDLReference.ps1` queries all Component_Registry rows where `doc_page_id IS NOT NULL`, groups them by `doc_page_id`, identifies the primary row, and writes `doc-registry.json` to `public/docs/data/ddl/`. This file is consumed by `nav.js` for navigation and by the hub page for the module card grid.

Structure per page entry:

```json
{
    "pageId": "serverhealth",
    "title": "Server Health",
    "sortOrder": 20,
    "isHub": false,
    "sections": [
        {
            "component": "ServerOps.ServerHealth",
            "description": "Real-time SQL Server performance...",
            "jsonSchema": "ServerOps",
            "jsonCategories": "Activity,Disk",
            "sectionOrder": 1,
            "ccSlug": null
        }
    ]
}
```

Key behaviors:
- `sortOrder` comes from the primary row's `doc_sort_order`. Pages with `sortOrder = null` are excluded from the top-level nav (they only appear as children).
- `isHub` is true when `sortOrder = 0`.
- `title` comes from the primary row's `doc_title`.
- Each section carries `ccSlug` from `doc_cc_slug` (null when not a named CC guide page).
- The `sections` array is ordered by `doc_section_order`.

#### Filename Conventions

`nav.js` derives filenames from `pageId` using fixed suffix conventions:

| Page Type | Filename | Subfolder | Example |
|-----------|----------|-----------|---------|
| Narrative | `{pageId}.html` | `pages/` | `serverhealth.html` |
| CC Guide (single) | `{pageId}-cc.html` | `pages/cc/` | `serverhealth-cc.html` |
| CC Guide (named) | `{pageId}-cc-{slug}.html` | `pages/cc/` | `controlcenter-cc-admin.html` |
| Architecture | `{pageId}-arch.html` | `pages/arch/` | `serverhealth-arch.html` |
| Reference | `{pageId}-ref.html` | `pages/ref/` | `serverhealth-ref.html` |

The full directory structure:

```
docs/
+-- pages/
|   +-- index.html                          <- Hub page (sortOrder 0)
|   +-- {pageId}.html                       <- Narrative pages
|   +-- cc/
|   |   +-- {pageId}-cc.html                <- CC guide (single, standard)
|   |   +-- {pageId}-cc-{slug}.html         <- CC guide (named, multiple)
|   +-- arch/
|   |   +-- {pageId}-arch.html              <- Architecture pages
|   +-- ref/
|       +-- {pageId}-ref.html               <- Reference pages
+-- data/ddl/
|   +-- doc-registry.json                   <- Page registry (drives nav.js)
|   +-- {Schema}.json                       <- Per-schema DDL (drives ddl-loader.js)
+-- css/
|   +-- docs-base.css, docs-narrative.css, docs-architecture.css, etc.
+-- js/
    +-- nav.js                              <- Navigation (reads doc-registry.json)
    +-- ddl-loader.js                       <- Reference page renderer
    +-- ddl-erd.js                          <- ERD diagram renderer
```

#### nav.js Page Discovery

`nav.js` loads `doc-registry.json` synchronously on every page load and performs two rendering passes:

**Pass 1 (immediate):** Renders the top-level nav bar using `pageId` and `title` from each registry entry with `sortOrder` populated. The current page is detected by matching the browser's filename against all possible `pageId` + suffix combinations. The current page gets a `.current` class; all others are links.

**Pass 2 (async child discovery):** For the current page (if not the hub), checks for the existence of child pages via HEAD requests. Three child types are checked in display order:

| Priority | Suffix | Folder | Default Label |
|----------|--------|--------|---------------|
| 1 | `-cc` | `cc/` | "Control Center" |
| 2 | `-arch` | `arch/` | "Architecture" |
| 3 | `-ref` | `ref/` | "Reference" |

If a child file exists, it appears as a `>` indented link below the parent in the nav. The current child page gets `.current` styling; siblings are clickable links.

**Named CC guide pages** extend this discovery. When the current page's registry entry has sections with non-null `ccSlug` values, nav.js checks for `{pageId}-cc-{slug}.html` files in addition to (or instead of) the standard `{pageId}-cc.html`. Each discovered named guide appears as a separate child link using the `doc_title` from its section row as the nav label, rather than the generic "Control Center" label.

When a `pageId` has **both** a standard `{pageId}-cc.html` and named `{pageId}-cc-{slug}.html` files, only the named ones are rendered -- the presence of any `ccSlug` entries in the registry suppresses the standard single-file check for that `pageId`. This prevents a confusing mix of generic and named links.

**Current page detection for named CC guides:** `nav.js` must also detect when the browser is currently on a named CC guide page. The filename `controlcenter-cc-admin.html` maps to `pageId = 'controlcenter'` with child type `-cc` and slug `admin`. The `detectCurrent()` function checks against all `ccSlug` values in the current page's sections to resolve this.

#### Multiple CC Guide Pages

The standard documentation convention is one CC guide page per `pageId`: `{pageId}-cc.html`. This works for modules where one CC page covers everything.

When a `pageId` needs multiple CC guide pages -- because its Control Center presence spans multiple distinct pages with different functionality -- the `doc_cc_slug` column on Component_Registry enables named CC guide pages.

**How it works:**

1. Set `doc_page_id` on the component row to the parent page's `pageId` (e.g., `controlcenter`).
2. Set `doc_cc_slug` to a short identifier (e.g., `admin`, `platform`).
3. Set `doc_title` to the nav display label (e.g., `Administration Guide`).
4. Create the HTML file at `pages/cc/{pageId}-cc-{slug}.html` (e.g., `controlcenter-cc-admin.html`).

**Naming rules for `doc_cc_slug`:**
- Lowercase, no spaces, no special characters. Hyphens are acceptable for multi-word slugs.
- Must be unique within a `pageId` (two components under the same `doc_page_id` cannot share a slug).
- The slug appears in the filename, so keep it short and descriptive.

**Example: The Control Center with multiple CC guide pages:**

| component_name | doc_page_id | doc_title | doc_sort_order | doc_cc_slug |
|---|---|---|---|---|
| ControlCenter.Shared | controlcenter | The Control Center | 130 | *(NULL)* |
| ControlCenter.Admin | controlcenter | Administration Guide | *(NULL)* | admin |
| ControlCenter.Platform | controlcenter | Platform Monitoring Guide | *(NULL)* | platform |

This produces three files under the `controlcenter` pageId:
- `controlcenter.html` -- Narrative (from `ControlCenter.Shared` primary row)
- `controlcenter-cc-admin.html` -- Admin CC guide (from `doc_cc_slug = 'admin'`)
- `controlcenter-cc-platform.html` -- Platform CC guide (from `doc_cc_slug = 'platform'`)

The nav for this page renders as:

```
The Control Center  > Administration Guide  > Platform Monitoring Guide  > Architecture
```

**Backward compatibility:** Modules with a single CC guide page (`doc_cc_slug = NULL` on all rows) continue to use the `{pageId}-cc.html` convention with no changes. The slug mechanism only activates when at least one section row has `doc_cc_slug` populated.

**Future use cases:** This pattern applies anywhere a module's Control Center presence spans multiple pages. For example, if Server Health adds a separate Performance Analysis page with its own CC guide:

| component_name | doc_page_id | doc_title | doc_cc_slug |
|---|---|---|---|
| ServerOps.ServerHealth | serverhealth | Server Health | *(NULL -- primary row)* |
| ServerOps.ServerHealth | serverhealth | Performance Analysis Guide | analysis |

### 6.2 Documentation Publishing Pipeline

Documentation is maintained in HTML only. Two additional output formats are generated automatically by `Publish-ConfluenceDocumentation.ps1`:

| Output | Format | Purpose | Location |
|--------|--------|---------|----------|
| **Confluence** | Storage Format (XHTML) | Published to Confluence Server via REST API | Confluence ITDOC space |
| **Markdown** | `.md` files | AI context files for Claude project knowledge | `docs/data/md/` |

**No direct edits to Confluence pages.** All documentation changes happen in the HTML source. The publisher script converts and uploads. If something looks wrong in Confluence, fix the HTML and re-publish.

**No direct edits to markdown exports.** These are regenerated from HTML on every publish run. Manual edits will be overwritten.

**How the publisher works:**

The script dynamically discovers pages from `doc-registry.json` (no manual registry entries needed). It reads HTML narrative, architecture, and CC guide pages, converts them to Confluence Storage Format (XHTML with Confluence-specific macros), and creates or updates pages via the Confluence REST API. It also reads the schema JSON files and generates full reference pages with expandable sections for each object. CC guide pages are processed with a dedicated phase that strips browser-only elements (screenshot containers, sticky reference zones) before conversion. A parallel markdown export runs on every execution, producing combined narrative + architecture + reference files per module.

Key conversions the publisher performs:

| HTML Element | Confluence Output | Markdown Output |
|-------------|-------------------|-----------------|
| `div.context-bar` | Info panel with "Overview" title | Block quote |
| `div.tech-tip` | Tip panel | Block quote with "**Tech Tip:**" prefix |
| `div.flow-diagram` | Arrow-separated table | Arrow-separated text |
| `div.diagram-placeholder` | Note panel with label and description | Descriptive text block |
| `div.erd-root` | PlantUML entity diagram (generated from JSON) | Text-based ERD listing |
| `table.info-table` | Standard Confluence table | Markdown table |
| `a.ref-inline` | Plain `<code>` text (links stripped) | Plain code text |
| `div.callout` (info, tip, warning, story) | Corresponding Confluence panel macro | Block quote with prefix |
| `div.expand-card` | Confluence expand macro with `<hr/>` separators | Collapsible section |
| CC guide: `div.sticky-ref-zone` | Stripped (browser-only interactive element) | Not exported |
| CC guide: `div.cc-guide-content` | Section content extracted and published | Not exported |
| Page header, nav, footer | Stripped (Confluence has its own) | Stripped |

**ERD generation:** The publisher reads the same JSON files used by the web ERD renderer and converts them to PlantUML entity diagrams showing PK/FK columns and relationships. The `data-schema` and `data-category` attributes on `erd-root` divs control which tables appear, matching the web behavior exactly.

**Diagram placeholders:** HTML architecture pages use `div.diagram-placeholder` for flow diagrams and state machines that haven't been converted to a rendered format yet. These render as descriptive note panels in Confluence and descriptive text in markdown. As these are replaced with actual visual elements in the HTML, corresponding publisher conversions will be added.

**Running the publisher:**

```powershell
# Preview (no changes)
.\Publish-ConfluenceDocumentation.ps1

# Publish specific module
.\Publish-ConfluenceDocumentation.ps1 -Execute -Module teams

# Publish all modules
.\Publish-ConfluenceDocumentation.ps1 -Execute

# Markdown export only (no Confluence publishing)
.\Publish-ConfluenceDocumentation.ps1 -ExportOnly
```

**Adding a new module to the publisher:** The publisher dynamically discovers pages from `doc-registry.json` -- no manual registry entries needed. Ensure the Component_Registry has `doc_page_id` and `doc_sort_order` set on the primary row, `doc_json_schema` set on any component that contributes reference content (required for both HTML rendering and Confluence publishing -- see `doc_json_schema` in Section 6.1.1), and that the HTML files exist at the expected paths. Run the DDL generation step first to regenerate `doc-registry.json`, then the publisher will find everything automatically.

#### Confluence Output Formatting Targets

The publisher aims to produce Confluence pages that match established formatting conventions. When refining publisher output, these are the target patterns:

**Confluence Storage Format macros used:**

| Macro | Purpose | HTML Source |
|-------|---------|-------------|
| `info` | Overview panels, informational callouts | `context-bar`, `callout info` |
| `tip` | Technical tips and non-obvious details | `tech-tip`, `callout tip` |
| `warning` | Warning callouts | `callout warning` |
| `note` | Story callouts, diagram placeholders | `callout story`, `diagram-placeholder` |
| `expand` | Collapsible sections (reference page objects) | Generated from JSON |
| `code` | SQL code blocks (common queries) | Generated from JSON |
| `plantuml` | Entity relationship diagrams | Generated from JSON via `erd-root` divs |
| `expand` | Collapsible content sections (architecture/narrative) | `expand-card` |

**Entity encoding requirements:** Confluence Storage Format requires numeric entities for special characters: `&mdash;` -> `&#8212;`, `&rarr;` -> `&#8594;`, `&larr;` -> `&#8592;`, `&nbsp;` -> `&#160;`, `&hellip;` -> `&#8230;`, `&ndash;` -> `&#8211;`.

**XHTML compliance:** All tags must be properly closed. Self-closing `<br/>` required (not `<br>`). CSS variable references in inline styles must be stripped (Confluence doesn't support them).

**Reference page structure in Confluence:** Each object renders as a top-level expand section titled `ObjectName (Type)`. Within each expand: module/category line, description, data flow (info panel), then expandable subsections for Fields, Parameters, Indexes, Check Constraints, Foreign Keys, Design Notes, Status Values, Common Queries, and Relationships. Empty sections are omitted.

**Areas for future publisher refinement:**
- Flow diagrams: currently rendered as arrow-separated tables. Target: PlantUML activity diagrams or equivalent visual rendering.
- State machines: currently in diagram placeholders. Target: PlantUML state diagrams.
- Side-by-side layouts: currently two-column tables. May benefit from Confluence column macros.
- Color samples: currently stripped. Consider emoji or status lozenge equivalents.

### 6.3 HTML Page Conventions

When building or editing documentation pages, use these CSS classes and HTML patterns. They are recognized by the publisher for cross-format conversion and by the documentation site CSS for consistent styling.

**Narrative pages** (`docs-narrative.css`):

| Element | Usage |
|---------|-------|
| `div.page-header` > `h1` + `div.subtitle` | Page title and tagline. Stripped by publisher. |
| `div.doc-nav` | Navigation placeholder. Populated by `nav.js`. Stripped by publisher. |
| `div.context-bar` | "Where this fits" overview paragraph. Converts to info panel. |
| `div.section` > `h2` | Major content sections. Divs are stripped; headings survive. |
| `div.flow-diagram` > `div.flow-steps` > `div.flow-step` | Visual flow diagrams with colored step boxes. |
| `table.info-table` | Structured comparison tables. Class is stripped for Confluence. |
| `a.ref-inline` | Inline links to reference page objects. Stripped to plain code in exports. |
| `div.doc-footer` | Back links and attribution. Stripped by publisher. |

**Architecture pages** (`docs-architecture.css`, `docs-erd.css`):

| Element | Usage |
|---------|-------|
| `div.section-nav` > `div.section-nav-links` | Sticky section navigation with anchor links. Stripped by publisher. |
| `div.erd-root` | ERD container. Attributes: `data-schema` (required), `data-category` (optional). Rendered by `ddl-erd.js` in browser, converted to PlantUML in Confluence. |
| `div.tech-tip` | Non-obvious technical detail. Converts to tip panel. |
| `div.diagram-placeholder` > `div.placeholder-label` + `div.placeholder-desc` | Placeholder for future visual diagrams. Converts to note panel. |
| `div.expand-card` > `div.expand-card-title` + `div.expand-card-body` | Collapsible content sections (how-to guides, configuration inventories). Click to toggle. Converts to Confluence expand macro with `<hr/>` separators. |

**Reference pages** (`docs-reference.css`):

| Element | Usage |
|---------|-------|
| `div.ddl-root` | Reference content container. Attributes: `data-schema` (required), `data-group` (display label), `data-category` (optional comma-separated filter), `data-objects` (legacy comma-separated explicit list -- prefer automatic category-based discovery). Content auto-rendered by `ddl-loader.js`. |

**CC guide pages** (`docs-controlcenter.css`, `docs-controlcenter.js`):

| Element | Usage |
|---------|-------|
| `div.sticky-ref-zone` | Top-level container for the sticky reference area (key cards + mockup + sidebar). Stays visible while reading. |
| `div.key-section` > `div.key-flip-grid` > `div.key-flip-card` | Flip-card grid explaining page-specific UI elements. Click to flip for description. |
| `div.overview-section` > `div.mock-container` | Page mockup diagram container. Contains all mock elements and callout markers. |
| `a.callout-marker` | Numbered circle overlaid on the mockup. Links to `#section-N`. Managed by `docs-controlcenter.js` (pulsing, visited, flash states). |
| `div[data-section="N"]` | Mock elements that highlight when the corresponding marker or sidebar item is clicked. |
| `div.mock-modal-preview` | Hidden overlay shown when its `data-section` marker is clicked. Used for slideout/modal previews on pages like Administration. Hidden by default; shown via `.mock-highlight` class. |
| `div.sticky-ref-sidebar` | Right column with "About This Page" intro and clickable section index. |
| `div.sidebar-item[data-marker="N"]` | Sidebar items that highlight the corresponding mockup section when clicked. |
| `div.cc-guide-content` > `div.guide-section#section-N` | Hidden section content used as data source for the slideout panel. Not visible on the page. |
| `div.guide-slideout` | Right-side slideout panel (outside `page-wrapper`). Contains tour/show-all mode toggle and progressive section slots. |
| `div.callout` (info, tip, warning) | Callout boxes within section content. Same classes as narrative/architecture pages. |

**Important:** When introducing new visual elements or CSS classes in HTML pages, consider the publisher impact. If a new element carries meaningful content, a corresponding conversion rule needs to be added to `Publish-ConfluenceDocumentation.ps1` to ensure it renders properly in Confluence and markdown exports. Purely decorative elements (borders, colors, spacing) don't need conversion rules -- they'll be stripped with generic div removal.

### 6.4 Standalone Guide Pages

Guide pages are standalone walkthrough documents that live in `pages/guides/` and are auto-discovered by the publisher. No registry file or Component_Registry entry is needed -- drop an HTML file in the folder and run the pipeline.

**Auto-discovery contract (required for the publisher to find and process the page):**

| Requirement | Purpose | Example |
|-------------|---------|---------|
| File location | `public/docs/pages/guides/*.html` | `pages/guides/bdl-import-guide.html` |
| `<h1>` tag | Publisher extracts this as the Confluence page title | `<h1>BDL Import -- User Guide</h1>` |
| Breadcrumb nav | Publisher extracts parent pageId from the `<a href>` | `<div class="doc-nav"><a href="../tools.html">Tools</a><span class="sep">-</span><span class="current">BDL Import Guide</span></div>` |

If either the `<h1>` or breadcrumb link is missing, the publisher logs a warning and skips the file.

**Parent page resolution:** The `href` in the breadcrumb link determines which page the guide appears under in Confluence. `../tools.html` -> parent is the Tools narrative page. `../controlcenter.html` -> parent is The Control Center. The parent must be a registered page in `doc-registry.json` (i.e., it must have a Component_Registry row with `doc_page_id`).

**Publisher processing (Phase 1.7):**
- Strips embedded `<style>` blocks, guide mockup divs (depth-counted), jump nav, step badges, all `<span>` tags, and guide-specific visual elements
- Adds an info banner: "This page is a text reference version..."
- Extracts `page-wrapper` content using `</body>` anchor (guide pages have no `<script>` tags)
- Delegates remaining content to the standard narrative converter

**Markdown export:** Guide pages are appended to their parent module's combined markdown file with a `---` separator.

**Object_Registry:** Each guide page should have an Object_Registry entry under the `Documentation.Site` component with `object_category = 'Documentation'` and `object_type = 'HTML'`.

**Adding a new guide page checklist:**
1. Create the HTML file in `pages/guides/` with `<h1>` title and breadcrumb nav linking to the parent page
2. Add an Object_Registry row
3. Run the documentation pipeline from the Admin modal -- the page is auto-discovered and published

### 6.5 File Headers

See Section 2.6.2 for the complete file header standards, including the platform-wide version-in-System_Metadata rule and how header construct is governed per file type. In brief: SQL object headers are described below; PowerShell file headers are defined by the PowerShell spec; and Control Center CSS and JavaScript headers are defined by the CSS and JavaScript specs respectively. Build each file type's header to the standard that governs it rather than to a one-size-fits-all template.

**SQL objects** use this block comment format:

```sql
/*
================================================================================
 Object:      SchemaName.ObjectName
 Type:        Stored Procedure / DDL Trigger / DML Trigger
 Version:     Tracked in dbo.System_Metadata (component: SchemaName.ComponentName)
 Purpose:     Brief description. Can span multiple lines if needed -
              indent continuation lines to align.
================================================================================

 CHANGELOG:
 ----------
 Date        Description
 ----------  -----------------------------------------------------------
 YYYY-MM-DD  Most recent changes first
 YYYY-MM-DD  Initial implementation

================================================================================
*/
```

---

## 7. Integration Standards

### 7.1 Teams Integration

> **PENDING DOCUMENTATION.** Teams alerting is queue-driven: scripts call the shared `Send-TeamsAlert` function (in `xFACts-OrchestratorFunctions.ps1`), which inserts into `Teams.AlertQueue` for delivery by `Process-TeamsAlertQueue.ps1`. The function enforces mandatory deduplication against `Teams.RequestLog` (no opt-out -- callers needing repeat alerts pass a unique trigger value) and supports both plain-text alerts and rich Adaptive Card payloads via an optional card-JSON parameter. The full webhook/delivery mechanics and card-formatting conventions are not yet cataloged in detail; a complete write-up is pending a dedicated integration investigation (tracked on the backlog).

### 7.2 Jira Integration

> **PENDING DOCUMENTATION.** Jira ticket creation is queue-driven, paralleling the Teams pattern: requests are queued via `Jira.TicketQueue` and processed by `Process-JiraTicketQueue.ps1`, which interacts with the Jira REST API and applies its own deduplication. The precise queue schema, REST interaction, and dedup logic are not yet cataloged; a complete write-up is pending the same integration investigation (tracked on the backlog).

### 7.3 Alert Deduplication

> **PENDING DOCUMENTATION.** Both the Teams and Jira integrations deduplicate before sending -- a combination of trigger-based suppression (a trigger type plus a trigger value identifying the specific instance) and a lookback against the integration's request/log table. The exact dual-level pattern and its lookback semantics are not yet cataloged; covered by the integration investigation on the backlog.

### 7.4 GitHub Integration

The xFACts platform publishes a complete snapshot of all platform files to a GitHub repository (`tnjazzgrass/xFACts`) via the GitHub Contents API. This serves as a versioned archive and as a mechanism for providing file content to Claude at the start of working sessions, eliminating the need to manually upload files.

**Repository:** https://github.com/tnjazzgrass/xFACts

**Four top-level folders:**

| Folder | Content |
|--------|---------|
| `xFACts-PowerShell/` | Orchestrator scripts, collector scripts, shared functions |
| `xFACts-ControlCenter/` | Route files, API files, CSS, JS, documentation site pages, DDL JSON |
| `xFACts-Documentation/` | Working documents, planning documents, guidelines |
| `xFACts-SQL/` | Stored procedure and trigger definitions |

**Publishing:** `Publish-GitHubRepository.ps1` handles all publishing. It collects files from the server source directories, extracts SQL object definitions from the database, generates Platform Registry markdown, audits all files against Object_Registry, compares the local inventory against the current repo state, and pushes only changed files. A `manifest.json` is generated and pushed as the final step. The script runs standalone or as a step in the `Invoke-DocPipeline.ps1` pipeline (triggered from the Admin page Documentation modal).

#### 7.4.1 Manifest Structure

The manifest system uses a two-tier structure: a lightweight master index at the repo root, plus category-specific sub-manifests containing the actual file entries.

**Master manifest** (`manifest.json` at repo root) contains only metadata and links to sub-manifests:

```json
{
    "generated": "2026-04-04T10:18:11Z",
    "repository": "https://github.com/tnjazzgrass/xFACts",
    "base_raw_url": "https://raw.githubusercontent.com/tnjazzgrass/xFACts/main",
    "file_count": 369,
    "manifests": [
        {
            "category": "Control Center Application",
            "filename": "manifest-cc-app.json",
            "raw_url": "https://raw.githubusercontent.com/.../manifest-cc-app.json?v=20260404101811",
            "file_count": 81
        },
        ...
    ]
}
```

**Sub-manifests** (at repo root alongside the master) contain the actual file entries with raw URLs and Object_Registry metadata:

| Sub-manifest | Content | Typical Size |
|---|---|---|
| `manifest-cc-app.json` | CC routes, APIs, JS, CSS, modules, startup | ~80 files |
| `manifest-cc-docs.json` | Docs pages, docs CSS/JS, DDL JSON, doc-registry | ~90 files |
| `manifest-powershell.json` | Orchestrator scripts, collectors, shared functions | ~35 files |
| `manifest-sql.json` | Stored procedure and trigger definitions | ~15 files |
| `manifest-documentation.json` | Planning docs, guidelines, backlog, working files (incl. VBA extracts) | ~150 files |

The ControlCenter split uses a simple path rule: files under `xFACts-ControlCenter/public/docs/` go to `cc-docs`, everything else under `xFACts-ControlCenter/` goes to `cc-app`.

Each sub-manifest file entry includes `path`, `raw_url` (with cache-buster), and optionally `module` and `component` from the Object_Registry audit. The cache-buster timestamp is shared across the master and all sub-manifests for a given publish run.

This segmentation prevents fetch truncation as the repository grows. The master manifest is under 1KB. Individual sub-manifests stay well within safe fetch limits even with hundreds of files.

#### 7.4.2 Claude Session Workflow

To provide Claude with access to repository files at the start of a session:

1. **Provide the master manifest URL** with a unique cache-buster value:
```
    https://raw.githubusercontent.com/tnjazzgrass/xFACts/main/manifest.json?v=20260404
```

2. **Claude fetches the master manifest.** This is a small JSON index containing sub-manifest URLs and file counts per category. No token limit concerns -- the master is under 1KB.

3. **Claude fetches the relevant sub-manifests** based on the session's focus area. For example, a BDL session would fetch `manifest-documentation.json` and `manifest-cc-app.json`. A DmOps session might fetch `manifest-powershell.json` and `manifest-documentation.json`. Fetching a sub-manifest unlocks all file URLs within it.

4. **Claude fetches individual files on demand** using the `raw_url` from the sub-manifest entries. The per-file cache-buster timestamps ensure CDN-fresh content.

**Key principle:** Only fetch the sub-manifests needed for the current task. There is no need to fetch all sub-manifests at session start. The master manifest provides enough context (category names and file counts) to determine which sub-manifests are relevant.

**Cascading URL unlock pattern:** The `web_fetch` tool only recognizes URLs that appeared in the text of a previous fetch. Fetching the master unlocks the sub-manifest URLs. Fetching a sub-manifest unlocks all file URLs within it. This is a two-hop chain instead of the previous single-hop pattern, but each hop is small and reliable.


#### 7.4.3 Known Limitations and Workarounds

**Manifest must not be truncated.** If Claude sets a token limit on the manifest fetch, only the first handful of file URLs (those visible before truncation) will be fetchable. All others will fail with permission errors. The fix is to re-fetch the manifest without a token limit. This is the single most common cause of file access failures.

**GitHub CDN caching.** `raw.githubusercontent.com` caches responses via Fastly CDN with a TTL of approximately 5 minutes. The per-file cache-buster query parameters (`?v=YYYYMMDDHHMMSS`) bypass this by making each publish cycle's URLs unique. However, if Claude falls back to a bare URL without a query string (e.g., due to permission issues), it may receive stale cached content. Always use the manifest URLs with their cache-busters, not bare URLs.

**CDN MIME type caching.** If a file is pushed to GitHub with invalid encoding (e.g., Windows-1252 characters in a nominally UTF-8 file), GitHub's CDN may classify it as `application/octet-stream` (binary) and the `web_fetch` tool will return `[binary data]` instead of text. Fixing the file encoding and re-pushing does not always clear this classification immediately -- the CDN may cache the binary MIME type for the bare URL even after the fix. The cache-buster query parameters bypass this: using the manifest URL with its timestamp will return the corrected file with `text/plain; charset=utf-8`. If a specific file persistently returns as binary on the bare URL, making any edit to the file and committing forces a new blob hash that triggers re-evaluation.

**File encoding requirements.** All files in the repository must be valid UTF-8 (or pure ASCII). Files containing Windows-1252 characters (e.g., byte `0x97` for em dash instead of the proper UTF-8 sequence `0xE2 0x80 0x94`) will be classified as binary by GitHub's content detection and will not be fetchable as text. VS Code may display such files as "UTF-8" because it does best-effort rendering, but the actual bytes are invalid. To verify: check the file with `[System.IO.File]::ReadAllBytes()` in PowerShell and look for any byte values above `0x7F` that are not part of valid multi-byte UTF-8 sequences.

**URL formatting in Claude chat.** The `web_fetch` tool requires URLs to be provided cleanly in the chat message. URLs wrapped in markdown formatting (surrounding underscores, bold markers, etc.) may not be recognized as user-provided URLs, causing permission errors. Paste URLs on their own line without any surrounding formatting characters.

**web_fetch rate limiting.** The `web_fetch` tool is subject to an hourly rate limit on total requests. The exact limit and reset timing are not visible to Claude -- there is no counter, no remaining-request header, and no way to check before a fetch fails. When the limit is hit, all fetches fail until the window resets (approximately one hour from the burst of activity that triggered it). This affects all web_fetch calls, not just GitHub URLs. To minimize the risk of hitting the limit mid-session:

- **Front-load all fetches at session start.** Pull the master manifest, relevant sub-manifests, and all files needed for the task in the first few minutes, before any code generation begins. If the limit is hit during front-loading, no work is lost.
- **Minimize redundant fetches.** Once a file is fetched, work from the in-context copy. Never re-fetch a file that is already in the conversation. Save files locally on first fetch when they will be edited.
- **Fetch only relevant sub-manifests.** A BDL session does not need the SQL or cc-docs sub-manifests. A DmOps session does not need cc-app. Selective fetching conserves the budget for individual file retrievals.
- **Avoid re-fetching the same large file.** If a file like the Development Guidelines was pulled early in the session, do not pull it again later -- use the copy already in context.
- **If the limit is hit mid-session,** wait approximately one hour for the window to reset. The limit is account-scoped, not chat-scoped -- starting a new chat does not reset it. The existing chat will work once the window cycles.

#### 7.4.4 Object_Registry Audit

The publish script audits every file being pushed against `dbo.Object_Registry` during Phase 5. Files with registry entries get `module` and `component` fields in the manifest. Files without entries are logged as warnings.

**Audit exclusions (by convention, not registered):**

| Exclusion | Reason |
|-----------|--------|
| `xFACts-Documentation/Planning/*` | Transient session documents, not platform objects |
| `xFACts-Documentation/*.md` | Standalone reference documents (Guidelines, Backlog, working docs) |
| `xFACts-ControlCenter/public/docs/data/ddl/*.json` | Generated output of Generate-DDLReference.ps1 |
| `Legacy` schema SQL objects | Deprecated, not tracked |
| Generated files (Platform Registry, manifest) | Runtime-generated, not authored objects |

**Path validation:** The audit also compares Object_Registry `object_path` against the actual source path for each matched file. Mismatches are logged as warnings. This catches registry paths that have drifted from the actual file system.

**Exit code convention:** Exit 0 = clean success (all green). Exit 2 = success with warnings (yellow warning indicator in the Admin modal, results auto-expand). Non-zero/non-2 = failure (red, pipeline halts).

#### 7.4.5 File Categories

The manifest assigns each file a category used for organization:

| Category | Source Directory | Content |
|----------|-----------------|---------|
| PowerShell | `E:\xFACts-PowerShell\` | All `.ps1` files (flat directory) |
| ControlCenter | `E:\xFACts-ControlCenter\` | Routes, APIs, modules, CSS, JS, documentation site |
| Documentation | `E:\xFACts-Documentation\` | Working docs, planning docs, guidelines |
| SQL | Extracted from database | Stored procedures, triggers (via `sys.sql_modules`) |

---

## 8. Anti-Patterns

Patterns that have been tried and rejected, or that should not be introduced on new work. Some of these are firm technical rules; others are the "preferred" side of a design preference (see Section 5) -- where a page has a documented reason to differ, that's a judgment call, not a violation. The intent is to capture what experience has shown causes problems, not to forbid every exception.

| Avoid | Prefer instead | Why |
|-------|----------------|-----|
| Bright progress bars that wash out overlaid text | Darker gradient that keeps centered text legible | Text-on-bar readability |
| Monospace for ordinary data display (counts, IDs, timestamps) | Segoe UI for data; Consolas for code identifiers only | Section 5.2 typography intent |
| Very light font weights for card display values on the dark theme | A normal weight with enough presence to read | Light weights wash out on dark backgrounds |
| Client-side health/staleness logic | API determines health from ProcessRegistry intervals; JS only renders | Single source of truth for "is this current" |
| Embedding counts in badge text ("Posting (1,500)") | A separate count column; badges show state only | Keeps state and magnitude legible separately |
| Raw backend status codes in display (e.g., `IMPORTFAILED`) | Friendly status mapping (e.g., "Import Failed") | Readability |
| Per-page engine-status polling endpoints | The shared WebSocket engine-event channel (Section 4.2) | One connection, one source of truth |
| Section-level refresh buttons | The single page-level refresh control in chrome | Consistency; avoids per-section drift |
| Hardcoded refresh timers in JavaScript | GlobalConfig-driven intervals loaded by shared infrastructure | Tunable without a code change |
| Duplicating chrome (nav, header, engine cards, refresh row) into page files | The CC zone's shared files as the single source; pages carry content only | The CSS/JS specs enforce this split |
| Saturated status fills | Colored text on a faint matching background tint | The house status pattern (Section 5.3) |

A few patterns this list previously stated as absolutes -- round status dots, occasional symbols, healthy-state color -- are better understood as preferences with legitimate exceptions; see Section 5 for the current, softened framing. Text pills and a calm healthy baseline are still the default, but a page with a real reason to differ is making a judgment call, not breaking a rule.

---

## Appendix A: Per-Page Specifics

This document no longer maintains a catalog of per-page exceptions. That catalog went stale as pages changed, and -- like the "reference implementation" callouts removed elsewhere in this pass -- it invited modeling new work after whatever a named page happened to be doing.

Per-page specifics now live in `dbo.Asset_Registry`, which catalogs every construct in every file for every page. When you need to know what a particular page actually uses -- its classes, its engine processes, its refresh configuration, anything that varies page to page -- query the registry rather than consulting a hand-maintained list. The registry is live and accurate by construction; a prose catalog here could only ever be a lagging snapshot.

The standard is the standard (Sections 4 and 5); genuine deviations live with the page that makes them and are discoverable in the registry.

# Object_Metadata: ControlCenter
Source: dbo.Object_Metadata
Generated: 2026-07-23 13:22:42

## Deploy-xFACts.ps1 (Script)

### category #0  [metadata_id: 5303]

Documentation.Pipeline

### data_flow #0  [metadata_id: 5304]

Reads the GitHub Personal Access Token from dbo.Credentials via Get-ServiceCredentials (ServiceName GitHub_xFACts) and injects it into each git command as a one-shot HTTP Authorization header. Fetches the target branch of tnjazzgrass/xFACts into the server-side staging clone (E:\xFACts-Staging by default), computes the files changed between the clone HEAD and the fetched branch, maps each changed authored repository path to its live location under E:\xFACts-PowerShell, E:\xFACts-ControlCenter, or E:\xFACts-Documentation via the authored deploy map, and copies the changed files there on -Execute. Generated repository paths (xFACts-Generated/*, the manifests, repository-root files) are never copied. Launched as the Deploy Authored Content step of the Admin page pipeline modal, or run standalone.

### description #0  [metadata_id: 5301]

The deploy half of the inverted xFACts sync: it deploys authored content from GitHub into the live server folders. GitHub is the source of truth for authored files, and this script brings the changed authored files into their live locations. Runs in preview by default and requires -Execute to pull and copy.

### design_note #1  [metadata_id: 5305]
Title: Staging Clone Verified, Never Created

The script verifies that the staging clone (E:\xFACts-Staging by default) exists, is a git working tree, and has its origin remote pointing at tnjazzgrass/xFACts; any failed check aborts the run. It never creates, clones, or repairs the staging directory - that one-time setup is a manual operation, so the deploy path can never silently stand up a clone against the wrong remote.

### design_note #2  [metadata_id: 5306]
Title: Per-Invocation Token, Never Persisted

The GitHub token is retrieved from dbo.Credentials at run time and passed to each git command as a single-use HTTP Authorization header via git -c http.extraHeader. It is never written to git config, the remote URL, or any file on disk, so the credential does not persist in the staging clone between runs.

### design_note #3  [metadata_id: 5307]
Title: Authored-Only Scope

Deploy copies only authored files, selected through an authored deploy map that is the inverse of the generated file map in Publish-GitHubRepository.ps1. Generated repository paths (xFACts-Generated/*, the manifests) and repository-root files are classified as ignored and never copied. The two maps partition the repository so that every managed path is either authored (deployed by this script) or generated (published in the other direction), never both and never neither.

### module #0  [metadata_id: 5302]

ControlCenter

## Generate-DDLReference.ps1 (Script)

### category #0  [metadata_id: 3090]

AdminTools

### data_flow #0  [metadata_id: 3102]

Executes inline SQL that queries the system catalog (sys.tables, sys.columns, sys.indexes, sys.check_constraints, sys.foreign_keys, sys.procedures, sys.parameters, sys.triggers, sys.objects, sys.views) and joins with dbo.Object_Metadata to produce enriched JSON. Scripts, XE Sessions, and DDL Triggers are sourced entirely from Object_Metadata. Returns one result set per schema via SqlDataReader, each written as an individual JSON file (e.g., ServerOps.json, JobFlow.json) to the documentation data directory, plus a _metadata.json with generation timestamp. These JSON files are consumed by ddl-loader.js on the reference pages.

### description #0  [metadata_id: 3088]

Generates comprehensive JSON reference documents containing all database object metadata across the xFACts platform. Inline SQL discovers active schemas dynamically, extracts complete catalog metadata, enriches it with Object_Metadata content (descriptions, design notes, queries, status values, relationship notes), and returns multiple result sets (one per schema plus a metadata set). Uses SqlDataReader to process the result sets and writes individual JSON files per schema to the documentation data directory. These JSON files are consumed by ddl-loader.js on the reference pages to dynamically render field tables, indexes, constraints, and descriptions. Supports preview mode (default) and execute mode.

### design_note #1  [metadata_id: 3103]
Title: Preview Mode

Runs in preview mode by default, showing what files would be generated without writing anything. The -Execute switch is required to actually write files. When launched from the Admin page Documentation card, -Execute is always passed.

### design_note #2  [metadata_id: 3333]
Title: Dynamic Schema Discovery

Schemas are not hardcoded. The SQL queries sys.schemas filtered to schemas that contain at least one user object or Object_Metadata row, excluding system schemas (sys, INFORMATION_SCHEMA, guest) and the Legacy schema. New schemas appear automatically when objects are created.

### design_note #3  [metadata_id: 3334]
Title: Object_Metadata as Documentation Source

All documentation content (descriptions, design notes, queries, status values, relationship notes, data flow) comes from dbo.Object_Metadata. Extended properties (MS_Description) are no longer read. Scripts, XE Sessions, and DDL Triggers are non-database objects documented solely through Object_Metadata rows.

### design_note #4  [metadata_id: 3335]
Title: Multi-Result-Set Output

The inline SQL returns one result set per schema, each containing SchemaName and SchemaJson columns. The script reads each with SqlDataReader.NextResult() and writes individual JSON files per schema. The final result set is a _metadata row with generation timestamp, database name, and server name.

### module #0  [metadata_id: 3089]

ControlCenter

### relationship_note #1  [metadata_id: 3104]
Title: Object_Metadata

Primary enrichment source. The inline SQL reads all property types (description, module, category, data_flow, design_note, query, status_value, relationship_note) for every object in each schema. Object_Metadata content is the sole source for all documentation text rendered on reference pages.

### relationship_note #2  [metadata_id: 3105]
Title: Documentation Pipeline

First step in the documentation pipeline. Runs before Publish-ConfluenceDocumentation.ps1 to ensure the JSON data files are current before Confluence publishing and markdown export consume them.

### relationship_note #3  [metadata_id: 3336]
Title: ddl-loader.js

Client-side consumer. Fetches the JSON files produced by the pipeline and renders documentation pages dynamically. The JSON structure produced by the inline SQL defines the contract that ddl-loader.js expects.

## Invoke-AssetRegistryPipeline.ps1 (Script)

### category #0  [metadata_id: 5092]

AdminTools

### description #0  [metadata_id: 5090]

Asset Registry pipeline orchestrator script. Runs the selected populators (CSS, HTML, JS, PS) in parallel as independent processes, then runs the reference resolver once the populators have completed. Writes real-time per-stage status to a JSON file as each stage progresses, enabling the Admin page to poll for progress updates. On a full run, truncates the Asset Registry before launching any stage; selective runs rely on each populator clearing its own rows. Halts before the resolver if a populator fails. Launched fire-and-forget by the /api/admin/asset-registry-pipeline endpoint.

### module #0  [metadata_id: 5091]

ControlCenter

## Invoke-DocPipeline.ps1 (Script)

### category #0  [metadata_id: 3087]

Documentation.Pipeline

### data_flow #0  [metadata_id: 3097]

Receives step selections and option flags from the Admin API endpoint. Launches each selected documentation script sequentially, capturing stdout and stderr per step. Writes real-time progress to E:\xFACts-PowerShell\Logs\doc-pipeline-status.json, which the Admin page polls every 2 seconds to display per-step status updates.

### description #0  [metadata_id: 3085]

Documentation pipeline wrapper script. Runs selected documentation steps (Generate DDL Reference, Publish to Confluence, Consolidate Upload Files) in sequence. Writes real-time status to a JSON file after each step completes, enabling the Admin page to poll for per-step progress updates. Launched fire-and-forget by the /api/admin/doc-pipeline endpoint.

### design_note #1  [metadata_id: 3098]
Title: Sequential Execution

Scripts always execute in fixed order (Generate DDL, Publish Confluence, Consolidate Upload) regardless of which steps are selected. If any step returns a non-zero exit code, the pipeline halts immediately and remaining steps are not attempted. The status JSON file is updated after each step completes, enabling the Admin page to show real-time progress.

### design_note #2  [metadata_id: 3099]
Title: Option Flags

Accepts switch parameters that are passed through to the worker scripts: -PublishToConfluence and -ExportMarkdown control the Publish step behavior, -IncludeSQLObjects and -IncludeJSON control the Consolidate step. The wrapper does not interpret these flags — it passes them as command-line arguments to the appropriate child script.

### module #0  [metadata_id: 3086]

ControlCenter

### relationship_note #1  [metadata_id: 3100]
Title: Admin Page

Launched fire-and-forget by POST /api/admin/doc-pipeline when a user clicks "Run Selected" on the Documentation card. The Admin page polls GET /api/admin/doc-pipeline/status to read the status JSON and update step indicators in real time.

### relationship_note #2  [metadata_id: 3101]
Title: Worker Scripts

Orchestrates up to three worker scripts in fixed order: Generate-DDLReference.ps1, Publish-ConfluenceDocumentation.ps1, and Consolidate-UploadFiles.ps1. Only scripts selected by the user are executed, but ordering is always preserved.

## Publish-ConfluenceDocumentation.ps1 (Script)

### category #0  [metadata_id: 3093]

AdminTools

### data_flow #0  [metadata_id: 3106]

Reads HTML narrative pages, architecture pages, and JSON DDL reference files from the documentation directory structure. Authenticates to Confluence Server using credentials from dbo.Credentials via two-tier decryption. Converts HTML to Confluence Storage Format and creates or updates pages in the target space via REST API, maintaining the page hierarchy. Also exports combined markdown files per module to the data\md directory for Claude project context uploads.

### description #0  [metadata_id: 3091]

Publishes xFACts documentation to Confluence Server via REST API and exports markdown files for Claude context upload. Reads HTML narrative pages, architecture pages, and JSON DDL reference files, converts to Confluence Storage Format, and creates or updates pages in the target space. Authenticates via dbo.Credentials two-tier decryption with fallback to manual prompt. Also generates PlantUML ERD diagrams from JSON data for architecture pages. Supports module filtering, preview mode, and export-only mode.

### design_note #1  [metadata_id: 3107]
Title: Execution Modes

Three modes of operation: preview mode (default) shows what would be published without making changes, -Execute publishes to Confluence and exports markdown, -ExportOnly skips Confluence publishing and only generates markdown files. Markdown export runs in all modes. Supports -Module to filter to a single module.

### design_note #2  [metadata_id: 3108]
Title: Headless Execution

All Invoke-WebRequest and Invoke-RestMethod calls use -UseBasicParsing to avoid the Internet Explorer engine dependency, which causes silent hangs in hidden/headless execution contexts. Credential retrieval falls back to interactive Get-Credential if dbo.Credentials lookup fails — this fallback will hang when launched headless from the Admin page.

### module #0  [metadata_id: 3092]

ControlCenter

### relationship_note #1  [metadata_id: 3109]
Title: dbo.Credentials

Authenticates to Confluence using the standard two-tier decryption pattern: master passphrase from dbo.GlobalConfig, service credentials from dbo.Credentials.

### relationship_note #2  [metadata_id: 3110]
Title: Documentation Pipeline

Second step in the documentation pipeline. Depends on Generate-DDLReference.ps1 having produced current JSON files. Output markdown files are collected by Consolidate-UploadFiles.ps1 in the third step.

## Publish-GitHubRepository.ps1 (Script)

### category #0  [metadata_id: 4043]

Documentation.Pipeline

### data_flow #0  [metadata_id: 4044]

Collects files from three server source directories (E:\xFACts-PowerShell, E:\xFACts-ControlCenter, E:\xFACts-Documentation) using configurable source mappings with filter and recurse options. Extracts SQL object definitions from sys.sql_modules on AVG-PROD-LSNR. Generates Platform Registry markdown by querying dbo.Module_Registry, dbo.Component_Registry, dbo.Object_Registry, and dbo.GlobalConfig. Retrieves the current repository state via the GitHub Git Trees API (recursive tree listing with blob SHAs), computes local git blob SHAs to identify creates, updates, and deletes without downloading remote content. Pushes changes via the GitHub Contents API (one commit per file). Generates and pushes manifest.json as the final step, cataloging all files with cache-busted raw URLs for Claude session access. Authenticates via PAT stored in dbo.Credentials (ServiceName: GitHub_xFACts).

### description #0  [metadata_id: 4041]

Publishes a complete snapshot of all xFACts platform files to a GitHub repository (tnjazzgrass/xFACts) via the GitHub Contents API. Collects files from server source directories, extracts SQL object definitions from the database, generates Platform Registry markdown from registry tables, compares local inventory against the current repo state via tree API, and pushes only changed files. Generates and pushes manifest.json as the final step, cataloging all files with cache-busted raw URLs for Claude session access.

### design_note #1  [metadata_id: 4045]
Title: SHA-Based Diff Without Downloads

Computes git blob SHA1 hashes locally using the same algorithm git uses internally (SHA1 of "blob <size>\0<content>"). Compares these against the remote tree SHAs retrieved via a single API call. This identifies exactly which files changed without downloading any remote file content, keeping API usage minimal.

### design_note #2  [metadata_id: 4046]
Title: BOM Stripping

Strips UTF-8 BOM (0xEF 0xBB 0xBF) from file content before computing SHAs and pushing to GitHub. PowerShell and some Windows editors add BOMs that GitHub does not expect, which would cause every file to appear as changed on every push and can trigger binary content detection.

### design_note #3  [metadata_id: 4047]
Title: Managed Prefix Scoping

Orphan detection (files in the repo not present locally) is scoped to four managed prefixes: xFACts-PowerShell/, xFACts-ControlCenter/, xFACts-Documentation/, xFACts-SQL/. Files outside these prefixes (such as manifest.json, README, .gitignore) are never deleted. This prevents the script from removing repo-level files it does not manage.

### design_note #4  [metadata_id: 4048]
Title: Generated File Tracking

SQL object definitions and Platform Registry markdown are generated at runtime rather than read from disk. These paths are tracked in a GeneratedRepoPaths list so orphan detection does not flag them for deletion — they exist only in memory during the publish run, not as files on the server file system.

### design_note #5  [metadata_id: 4049]
Title: Manifest Cache-Buster Pattern

Each file URL in manifest.json includes a query parameter (?v=YYYYMMDDHHMMSS) derived from the publish timestamp. This forces CDN cache misses when Claude fetches files via web_fetch, ensuring current content regardless of GitHub CDN TTL. The manifest itself requires a user-provided cache-buster when fetched at the start of a Claude session.

### design_note #6  [metadata_id: 4050]
Title: Rate Limit Awareness

Checks GitHub API rate limit on startup and warns if remaining calls are low. Inserts 100ms pauses between file push operations to stay within API rate limits during large pushes. The Contents API has a lower effective rate limit than the Git Data API.

### module #0  [metadata_id: 4042]

ControlCenter

### relationship_note #1  [metadata_id: 4051]
Title: Documentation Pipeline

Runs as a step in the Invoke-DocPipeline.ps1 pipeline, launched from the Admin page Documentation modal. Can also run standalone. When run via the pipeline, the -Execute switch is always passed.

### relationship_note #2  [metadata_id: 4052]
Title: dbo.Credentials

Retrieves GitHub Personal Access Token via Get-ServiceCredentials using ServiceName GitHub_xFACts. The PAT requires repo scope for Contents API access (create, update, delete files).

### relationship_note #3  [metadata_id: 4053]
Title: Platform Registry Tables

Queries dbo.Module_Registry, dbo.Component_Registry, dbo.Object_Registry, and dbo.GlobalConfig to generate xFACts_Platform_Registry.md as part of each publish run. This ensures the registry export in the repository always reflects the current database state.

### relationship_note #4  [metadata_id: 4054]
Title: Claude Session Access

The manifest.json produced by this script is the entry point for Claude to access repository content at the start of working sessions. Claude fetches the manifest to discover all file URLs, then fetches individual files on demand. The manifest must be fetched without token truncation for all URLs to be accessible.

## xFACts-DocPipelineFunctions.ps1 (Script)

### category #0  [metadata_id: 5135]

Documentation.Pipeline

### data_flow #0  [metadata_id: 5136]

Dot-sourced by Consolidate-UploadFiles.ps1 and Publish-GitHubRepository.ps1 after xFACts-OrchestratorFunctions.ps1. Get-SqlObjectDefinitions reads stored procedure, trigger, function, and view definitions from sys.sql_modules in the xFACts database and returns the raw rows so each consumer can write per-object .sql files. Get-RegistryExportMarkdown runs the registry export queries it holds, renders each result set as a markdown table, and returns the assembled Platform Registry markdown along with the count of tables rendered; the consumers write that markdown to a file and report the table count. The functions hold no state of their own; they read through the shared Get-SqlData against the connection target the calling script established with Initialize-XFActsScript.

### description #0  [metadata_id: 5133]

Shared scoped-function library for the documentation-pipeline scripts. Centralizes the user SQL object definition extraction and the Platform Registry markdown generation that the upload-consolidation and GitHub-publishing scripts previously duplicated. Dot-sourced after xFACts-OrchestratorFunctions.ps1, which supplies the Write-Log and Get-SqlData it calls.

### design_note #1  [metadata_id: 5137]
Title: No self-import of the orchestrator

As a shared-library file it declares no IMPORTS section, so it does not dot-source xFACts-OrchestratorFunctions.ps1 even though it depends on that file's Write-Log and Get-SqlData. Consuming scripts dot-source the orchestrator first, then this helper. This keeps the load order explicit at the call site and avoids a shared library reaching back into platform infrastructure.

### design_note #2  [metadata_id: 5138]
Title: Markdown generator returns content and table count

Get-RegistryExportMarkdown returns a hashtable carrying both the assembled markdown and the count of tables rendered, rather than the bare markdown string. The two consumers both write the markdown and report how many registry tables the snapshot covered, so the count is returned alongside the content rather than recomputed by each caller.

### design_note #3  [metadata_id: 5139]
Title: Scoped to the documentation pipeline

The extraction and registry-export logic was lifted into this scoped helper rather than into xFACts-OrchestratorFunctions.ps1 because only the documentation-pipeline scripts use it. Platform-wide infrastructure stays in the orchestrator; pipeline-specific shared logic lives here, next to the scripts that consume it.

### module #0  [metadata_id: 5134]

ControlCenter

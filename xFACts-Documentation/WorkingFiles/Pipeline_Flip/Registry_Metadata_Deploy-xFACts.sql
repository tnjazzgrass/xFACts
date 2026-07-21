-- ============================================================================
-- Pipeline Flip (Task 1) - Registry and Metadata for Deploy-xFACts.ps1
-- ----------------------------------------------------------------------------
-- Registers the new deploy-half script Deploy-xFACts.ps1 and retires the
-- superseded Consolidate-UploadFiles.ps1 in the platform catalog:
--   Section 1  Preview - current catalog state for both scripts
--   Section 2  Object_Registry - INSERT Deploy-xFACts.ps1
--   Section 3  Object_Registry - retire Consolidate-UploadFiles.ps1
--   Section 4  Object_Metadata - baseline + enrichment for Deploy-xFACts.ps1
--   Section 5  Object_Metadata - retire Consolidate-UploadFiles.ps1 rows
--   Section 6  Verification
-- Run section by section in SSMS. Sections 2-5 are idempotent (guarded).
-- Component: Documentation.Pipeline (module ControlCenter).
-- ============================================================================

USE xFACts;
GO

-- ============================================================================
-- SECTION 1: PREVIEW - current catalog state for both scripts
-- ----------------------------------------------------------------------------
-- Run first. Confirms Deploy-xFACts.ps1 is not yet registered and shows the
-- Consolidate-UploadFiles.ps1 rows that Sections 3 and 5 will retire.
-- ============================================================================

SELECT registry_id, module_name, component_name, object_name,
       object_category, object_type, object_path, is_active
FROM dbo.Object_Registry
WHERE object_name IN ('Deploy-xFACts.ps1', 'Consolidate-UploadFiles.ps1')
ORDER BY object_name;

SELECT schema_name, object_name, object_type, property_type,
       sort_order, title, is_active,
       LEFT(content, 80) AS content_preview
FROM dbo.Object_Metadata
WHERE object_name IN ('Deploy-xFACts.ps1', 'Consolidate-UploadFiles.ps1')
ORDER BY object_name, property_type, sort_order;

-- ============================================================================
-- SECTION 2: OBJECT_REGISTRY - INSERT Deploy-xFACts.ps1
-- ----------------------------------------------------------------------------
-- Classified per the existing pipeline-script pattern (see
-- Publish-GitHubRepository.ps1): module ControlCenter, component
-- Documentation.Pipeline, category PowerShell, type Script, full object_path.
-- is_active defaults to 1; zone/scope/scope_tier are populated later by the
-- Asset Registry parsers, so they are left unset here.
-- ============================================================================

IF NOT EXISTS (
    SELECT 1 FROM dbo.Object_Registry
    WHERE component_name = 'Documentation.Pipeline'
      AND object_name = 'Deploy-xFACts.ps1'
)
BEGIN
    INSERT INTO dbo.Object_Registry
        (module_name, component_name, object_name, object_category, object_type, object_path, description)
    VALUES
        ('ControlCenter', 'Documentation.Pipeline', 'Deploy-xFACts.ps1', 'PowerShell', 'Script',
         'E:\xFACts-PowerShell\Deploy-xFACts.ps1',
         'Deploys authored xFACts content from GitHub into the live server folders - the deploy half of the inverted sync. Verifies a server-side staging clone, pulls authored files with a per-invocation GitHub token, maps changed authored repository paths to their live locations and copies them, reports repository deletions without applying them, and holds back the two orchestrator files for a manual service-stop deployment.');
END
GO

-- ============================================================================
-- SECTION 3: OBJECT_REGISTRY - retire Consolidate-UploadFiles.ps1
-- ----------------------------------------------------------------------------
-- Established retirement pattern is soft delete: is_active = 0 (per the
-- object_path/is_active column definition, 0 = retired/dropped). No DELETE.
-- Object_Registry carries no modified_* columns, so only is_active is set.
-- ============================================================================

UPDATE dbo.Object_Registry
SET is_active = 0
WHERE component_name = 'Documentation.Pipeline'
  AND object_name = 'Consolidate-UploadFiles.ps1'
  AND is_active = 1;
GO

-- ============================================================================
-- SECTION 4: OBJECT_METADATA - baseline + enrichment for Deploy-xFACts.ps1
-- ----------------------------------------------------------------------------
-- schema_name ControlCenter, object_type Script (matches the existing
-- Documentation.Pipeline scripts). Three mandatory baselines (description,
-- module, category), one data_flow, and five design_note rows. All content is
-- derived from the script itself.
-- ============================================================================

IF NOT EXISTS (
    SELECT 1 FROM dbo.Object_Metadata
    WHERE schema_name = 'ControlCenter'
      AND object_name = 'Deploy-xFACts.ps1'
      AND object_type = 'Script'
)
BEGIN
    -- Baseline rows (mandatory)
    INSERT INTO dbo.Object_Metadata
        (schema_name, object_name, object_type, property_type, content)
    VALUES
        ('ControlCenter', 'Deploy-xFACts.ps1', 'Script', 'description',
         'The deploy half of the inverted xFACts sync: it deploys authored content from GitHub into the live server folders. GitHub is the source of truth for authored files, and this script brings the changed authored files into their live locations while leaving generated content untouched and repository deletions unapplied. Runs in preview by default and requires -Execute to pull and copy.'),
        ('ControlCenter', 'Deploy-xFACts.ps1', 'Script', 'module',   'ControlCenter'),
        ('ControlCenter', 'Deploy-xFACts.ps1', 'Script', 'category', 'Documentation.Pipeline');

    -- Data flow
    INSERT INTO dbo.Object_Metadata
        (schema_name, object_name, object_type, property_type, content)
    VALUES
        ('ControlCenter', 'Deploy-xFACts.ps1', 'Script', 'data_flow',
         'Reads the GitHub Personal Access Token from dbo.Credentials via Get-ServiceCredentials (ServiceName GitHub_xFACts) and injects it into each git command as a one-shot HTTP Authorization header. Fetches the target branch of tnjazzgrass/xFACts into the server-side staging clone (E:\xFACts-Staging by default), computes the files changed between the clone HEAD and the fetched branch, maps each changed authored repository path to its live location under E:\xFACts-PowerShell, E:\xFACts-ControlCenter, or E:\xFACts-Documentation via the authored deploy map, and copies the changed files there on -Execute. Generated repository paths (xFACts-Generated/*, the manifests, repository-root files) are never copied. Launched as the Deploy Authored Content step of the Admin page pipeline modal, or run standalone.');

    -- Design notes (sequential sort_order)
    INSERT INTO dbo.Object_Metadata
        (schema_name, object_name, object_type, property_type, sort_order, title, content)
    VALUES
        ('ControlCenter', 'Deploy-xFACts.ps1', 'Script', 'design_note', 1,
         'Staging Clone Verified, Never Created',
         'The script verifies that the staging clone (E:\xFACts-Staging by default) exists, is a git working tree, and has its origin remote pointing at tnjazzgrass/xFACts; any failed check aborts the run. It never creates, clones, or repairs the staging directory - that one-time setup is a manual operation, so the deploy path can never silently stand up a clone against the wrong remote.'),
        ('ControlCenter', 'Deploy-xFACts.ps1', 'Script', 'design_note', 2,
         'Per-Invocation Token, Never Persisted',
         'The GitHub token is retrieved from dbo.Credentials at run time and passed to each git command as a single-use HTTP Authorization header via git -c http.extraHeader. It is never written to git config, the remote URL, or any file on disk, so the credential does not persist in the staging clone between runs.'),
        ('ControlCenter', 'Deploy-xFACts.ps1', 'Script', 'design_note', 3,
         'Repository Deletions Reported, Not Applied',
         'Files removed upstream in the repository are never deleted from the live folders. The script detects authored paths deleted between the clone HEAD and the fetched branch, and when the matching live file still exists it reports it as DELETED-IN-REPO for manual handling. Deploy only ever adds or overwrites live files; removing a live file is always a human decision.'),
        ('ControlCenter', 'Deploy-xFACts.ps1', 'Script', 'design_note', 4,
         'Orchestrator Guard',
         'The two orchestrator files (xFACts-OrchestratorFunctions.ps1 and Start-xFACtsOrchestrator.ps1) are never auto-deployed, because the running orchestrator holds them open. When either changes upstream it is held back with a warning that it needs a manual service-stop deployment, and the run exits 2, while every other changed authored file still deploys normally.'),
        ('ControlCenter', 'Deploy-xFACts.ps1', 'Script', 'design_note', 5,
         'Authored-Only Scope',
         'Deploy copies only authored files, selected through an authored deploy map that is the inverse of the generated file map in Publish-GitHubRepository.ps1. Generated repository paths (xFACts-Generated/*, the manifests) and repository-root files are classified as ignored and never copied. The two maps partition the repository so that every managed path is either authored (deployed by this script) or generated (published in the other direction), never both and never neither.');
END
GO

-- ============================================================================
-- SECTION 5: OBJECT_METADATA - retire Consolidate-UploadFiles.ps1 rows
-- ----------------------------------------------------------------------------
-- Soft delete every metadata row for the retired script (per Section 2.9:
-- no DELETE, set is_active = 0). Object_Metadata carries modified_* columns.
-- ============================================================================

UPDATE dbo.Object_Metadata
SET is_active = 0,
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE schema_name = 'ControlCenter'
  AND object_name = 'Consolidate-UploadFiles.ps1'
  AND object_type = 'Script'
  AND is_active = 1;
GO

-- ============================================================================
-- SECTION 6: VERIFICATION
-- ----------------------------------------------------------------------------
-- Deploy-xFACts.ps1 registered and active; Consolidate-UploadFiles.ps1 retired.
-- ============================================================================

-- Registry: Deploy active (1 row), Consolidate inactive (is_active = 0)
SELECT module_name, component_name, object_name, object_category,
       object_type, object_path, is_active
FROM dbo.Object_Registry
WHERE object_name IN ('Deploy-xFACts.ps1', 'Consolidate-UploadFiles.ps1')
ORDER BY object_name;

-- Metadata: Deploy row counts by property_type (expect description 1, module 1,
-- category 1, data_flow 1, design_note 5)
SELECT property_type, COUNT(*) AS row_count
FROM dbo.Object_Metadata
WHERE schema_name = 'ControlCenter'
  AND object_name = 'Deploy-xFACts.ps1'
  AND object_type = 'Script'
  AND is_active = 1
GROUP BY property_type
ORDER BY property_type;

-- Metadata: Consolidate should have no active rows remaining
SELECT COUNT(*) AS consolidate_active_rows
FROM dbo.Object_Metadata
WHERE schema_name = 'ControlCenter'
  AND object_name = 'Consolidate-UploadFiles.ps1'
  AND object_type = 'Script'
  AND is_active = 1;
GO

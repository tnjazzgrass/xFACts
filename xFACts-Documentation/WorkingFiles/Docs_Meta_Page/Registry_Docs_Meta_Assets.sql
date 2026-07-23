-- ============================================================================
-- Register the documentation meta page family assets
--   Section 1  Preview - current catalog and version state
--   Section 2  Object_Registry - INSERT docs-meta.css
--   Section 3  Object_Registry - INSERT docs-meta.js
--   Section 4  System_Metadata - version bump for Documentation.Site
--   Section 5  Verification
-- Run section by section in SSMS. Sections 2-4 are idempotent (guarded).
-- Component: Documentation.Site (module ControlCenter).
--
-- Both files are page-type family assets in the docs zone, classified exactly
-- as the ten existing non-shell docs assets are: zone 'docs', scope 'SHARED',
-- scope_tier left NULL (SHELL is carried only by docs-base.css and
-- docs-shared.js). zone and scope are set here rather than left for a parser:
-- the Asset Registry CSS and JS populators READ zone and scope from
-- Object_Registry, and a scanned file with no active row is reported as
-- FILE_NOT_REGISTERED with its rows carrying a zone and scope of '<undefined>'.
-- ============================================================================

USE xFACts;
GO

-- ============================================================================
-- SECTION 1: PREVIEW - current catalog and version state
-- ----------------------------------------------------------------------------
-- Run first. Confirms neither asset is registered yet, shows the sibling docs
-- assets the two new rows are modelled on, and shows the current
-- Documentation.Site version that Section 4 bumps.
-- ============================================================================

SELECT registry_id, module_name, component_name, object_name,
       object_category, object_type, object_path, zone, scope, scope_tier, is_active
FROM dbo.Object_Registry
WHERE object_name IN ('docs-meta.css', 'docs-meta.js')
ORDER BY object_name;

SELECT registry_id, object_name, object_type, zone, scope, scope_tier, description
FROM dbo.Object_Registry
WHERE component_name = 'Documentation.Site'
  AND object_category = 'Documentation'
  AND is_active = 1
ORDER BY object_type, object_name;

SELECT TOP 5 metadata_id, version, description, deployed_date, deployed_by
FROM dbo.System_Metadata
WHERE component_name = 'Documentation.Site'
ORDER BY metadata_id DESC;

-- ============================================================================
-- SECTION 2: OBJECT_REGISTRY - INSERT docs-meta.css
-- ----------------------------------------------------------------------------
-- Page-type stylesheet for the meta pages, loaded after docs-base.css. Modelled
-- on the docs-controlcenter.css row (the existing page-type stylesheet).
-- ============================================================================

IF NOT EXISTS (
    SELECT 1 FROM dbo.Object_Registry
    WHERE component_name = 'Documentation.Site'
      AND object_name = 'docs-meta.css'
)
BEGIN
    INSERT INTO dbo.Object_Registry
        (module_name, component_name, object_name, object_category, object_type,
         object_path, zone, scope, description)
    VALUES
        ('ControlCenter', 'Documentation.Site', 'docs-meta.css', 'Documentation', 'CSS',
         'E:\xFACts-ControlCenter\public\docs\css\docs-meta.css',
         'docs', 'SHARED',
         'Meta page styles');
END
GO

-- ============================================================================
-- SECTION 3: OBJECT_REGISTRY - INSERT docs-meta.js
-- ----------------------------------------------------------------------------
-- Page-type renderer for the meta pages, loaded after docs-shared.js and
-- nav.js. Modelled on the docs-controlcenter.js row (the existing page-type
-- renderer).
-- ============================================================================

IF NOT EXISTS (
    SELECT 1 FROM dbo.Object_Registry
    WHERE component_name = 'Documentation.Site'
      AND object_name = 'docs-meta.js'
)
BEGIN
    INSERT INTO dbo.Object_Registry
        (module_name, component_name, object_name, object_category, object_type,
         object_path, zone, scope, description)
    VALUES
        ('ControlCenter', 'Documentation.Site', 'docs-meta.js', 'Documentation', 'JavaScript',
         'E:\xFACts-ControlCenter\public\docs\js\docs-meta.js',
         'docs', 'SHARED',
         'Meta page JSON loader and grid renderer');
END
GO

-- ============================================================================
-- SECTION 4: SYSTEM_METADATA - version bump for Documentation.Site
-- ----------------------------------------------------------------------------
-- Derives the next patch version from the current one. To bump the minor or
-- major element instead, set @next to the intended value after the SELECT that
-- derives it. The insert is skipped if that version already exists.
-- ============================================================================

DECLARE @current varchar(20);
DECLARE @next varchar(20);

SELECT TOP 1 @current = version
FROM dbo.System_Metadata
WHERE component_name = 'Documentation.Site'
ORDER BY metadata_id DESC;

SELECT @next = PARSENAME(@current, 3) + '.' + PARSENAME(@current, 2) + '.'
             + CAST(CAST(PARSENAME(@current, 1) AS int) + 1 AS varchar(10));

SELECT @current AS current_version, @next AS next_version;

IF @next IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM dbo.System_Metadata
    WHERE component_name = 'Documentation.Site'
      AND version = @next
)
BEGIN
    INSERT INTO dbo.System_Metadata
        (module_name, component_name, version, description, deployed_by)
    VALUES
        ('ControlCenter', 'Documentation.Site', @next,
         'Added the documentation meta page family: a backlog page that renders the authored backlog JSON as a filterable, sortable grid grouped by component with a per-row expandable detail drawer. Introduces the docs-meta.css and docs-meta.js family assets and a Tools page tile linking the new page.',
         SYSTEM_USER);
END
GO

-- ============================================================================
-- SECTION 5: VERIFICATION
-- ----------------------------------------------------------------------------
-- Both assets registered and active with zone docs and scope SHARED, and the
-- Documentation.Site version bump recorded.
-- ============================================================================

SELECT registry_id, object_name, object_category, object_type,
       object_path, zone, scope, scope_tier, is_active, description
FROM dbo.Object_Registry
WHERE object_name IN ('docs-meta.css', 'docs-meta.js')
ORDER BY object_name;

SELECT TOP 3 metadata_id, version, description, deployed_date, deployed_by
FROM dbo.System_Metadata
WHERE component_name = 'Documentation.Site'
ORDER BY metadata_id DESC;

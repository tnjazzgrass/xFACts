-- ============================================================================
-- Register the documentation meta page family assets
--   Section 1  Preview - current catalog state
--   Section 2  Object_Registry - INSERT docs-meta.css
--   Section 3  Object_Registry - INSERT docs-meta.js
--   Section 4  Object_Registry - INSERT backlog.html
--   Section 5  Verification
-- Run section by section in SSMS. Sections 2-4 are idempotent (guarded), so
-- re-running after the css and js rows already exist is safe.
-- Component: Documentation.Site (module ControlCenter).
--
-- Both files are page-type family assets in the docs zone, classified exactly
-- as the ten existing non-shell docs assets are: zone 'docs', scope 'SHARED',
-- scope_tier left NULL (SHELL is carried only by docs-base.css and
-- docs-shared.js). zone and scope are set here rather than left for a parser:
-- the Asset Registry CSS and JS populators READ zone and scope from
-- Object_Registry, and a scanned file with no active row is reported as
-- FILE_NOT_REGISTERED with its rows carrying a zone and scope of '<undefined>'.
--
-- No System_Metadata rows are written here. Per Development Guidelines 2.6.7 the
-- version bump is entered through the Administration page System Metadata panel,
-- where the version auto-increments; the SQL form is reserved for scripted
-- deployments and bulk operations. The two bump requests for this session are
-- supplied separately in the Section 2.6.7 request format.
-- ============================================================================

USE xFACts;
GO

-- ============================================================================
-- SECTION 1: PREVIEW - current catalog state
-- ----------------------------------------------------------------------------
-- Run first. Confirms neither asset is registered yet, and shows the sibling
-- docs assets whose classification the two new rows follow.
-- ============================================================================

SELECT registry_id, module_name, component_name, object_name,
       object_category, object_type, object_path, zone, scope, scope_tier, is_active
FROM dbo.Object_Registry
WHERE object_name IN ('docs-meta.css', 'docs-meta.js', 'backlog.html')
ORDER BY object_name;

SELECT registry_id, object_name, object_type, zone, scope, scope_tier, description
FROM dbo.Object_Registry
WHERE component_name = 'Documentation.Site'
  AND object_category = 'Documentation'
  AND is_active = 1
ORDER BY object_type, object_name;

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
-- SECTION 4: OBJECT_REGISTRY - INSERT backlog.html
-- ----------------------------------------------------------------------------
-- The page itself. Every one of the 66 existing doc-site pages carries a row,
-- so the new page needs one too; the deploy run flags it as UNREGISTERED until
-- it does. Pages are scope LOCAL (one consumer each), unlike the css and js
-- family assets above, which are SHARED.
-- ============================================================================

IF NOT EXISTS (
    SELECT 1 FROM dbo.Object_Registry
    WHERE component_name = 'Documentation.Site'
      AND object_name = 'backlog.html'
)
BEGIN
    INSERT INTO dbo.Object_Registry
        (module_name, component_name, object_name, object_category, object_type,
         object_path, zone, scope, description)
    VALUES
        ('ControlCenter', 'Documentation.Site', 'backlog.html', 'Documentation', 'HTML',
         'E:\xFACts-ControlCenter\public\docs\pages\backlog.html',
         'docs', 'LOCAL',
         'Platform backlog page - filterable view of the open backlog items');
END
GO

-- ============================================================================
-- SECTION 5: VERIFICATION
-- ----------------------------------------------------------------------------
-- All three objects registered and active: the css and js family assets with
-- zone docs and scope SHARED, and the page with zone docs and scope LOCAL.
-- ============================================================================

SELECT registry_id, object_name, object_category, object_type,
       object_path, zone, scope, scope_tier, is_active, description
FROM dbo.Object_Registry
WHERE object_name IN ('docs-meta.css', 'docs-meta.js', 'backlog.html')
ORDER BY object_type, object_name;

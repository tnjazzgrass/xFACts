/* ============================================================================
   xFACts Control Center - Documentation Site Reference Renderer (ddl-loader.js)
   Location: E:\xFACts-ControlCenter\public\docs\js\ddl-loader.js
   Version: Tracked in dbo.System_Metadata (component: Documentation.Site)

   Renders the technical reference pages from the per-schema DDL JSON. Discovers
   every doc-ddl-root mount on the page, loads its schema data, and builds the
   full object reference: section headers, schema field tables, the collapsible
   card stack each object's detail groups render into, and the enrichment content
   (data flow, design notes, status values, relationships, and copyable queries).
   It also builds the object jump-link navigation folded into the fixed header,
   flat or grouped by category, and wires the card, copy, and group-toggle
   interactions through delegated listeners. Consumes doc_esc and doc_fetchJson
   from docs-shared.js.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: RENDER CONFIGURATION
   STATE: SCHEMA CACHE AND TEMPLATES
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: PAGE DISCOVERY
   FUNCTIONS: SCHEMA LOADING
   FUNCTIONS: OBJECT DISCOVERY AND GROUPING
   FUNCTIONS: SCHEMA RENDERING
   FUNCTIONS: OBJECT RENDERERS
   FUNCTIONS: CARD BUILDER
   FUNCTIONS: OBJECT NAVIGATION
   FUNCTIONS: EVENT DELEGATION
   FUNCTIONS: FORMATTING HELPERS
   ============================================================================ */

/* ============================================================================
   CONSTANTS: RENDER CONFIGURATION
   ----------------------------------------------------------------------------
   The render configuration: the root-absolute path to the DDL data directory,
   the set of card labels open by default, the object-kind display order, and the
   JSON-array-to-kind mapping that drives object discovery.
   Prefix: doc
   ============================================================================ */

/* Root-absolute path to the DDL data directory, served by the /generated route. */
const doc_DATA_BASE_PATH = '/generated/ddl/';

/* Card labels rendered open by default; empty means every card starts closed. */
const doc_defaultOpenCards = [];

/* Object kinds in nav and render display order. */
const doc_typeOrder = ['table', 'proc', 'trigger', 'function', 'view', 'script'];

/* Maps each schema JSON array key to the object kind its entries represent. */
const doc_typeMap = {
    tables: 'table',
    procedures: 'proc',
    triggers: 'trigger',
    functions: 'function',
    views: 'view',
    scripts: 'script',
    xeSessions: 'xe',
    ddlTriggers: 'ddltrigger'
};

/* ============================================================================
   STATE: SCHEMA CACHE AND TEMPLATES
   ----------------------------------------------------------------------------
   The mutable runtime state built during a render pass: the per-schema JSON
   cache that avoids re-fetching a schema referenced by more than one mount, and
   the editorial template fragments collected from inline template elements and
   keyed by object name then insertion point.
   Prefix: doc
   ============================================================================ */

/* Caches each loaded schema's parsed JSON by schema name. */
var doc_schemaCache = {};

/* Holds editorial template fragments keyed by object name then section slot. */
var doc_templates = {};

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The page boot function: discovers the reference mounts and inline templates,
   loads and renders each mount's schema, builds the object navigation once all
   mounts resolve, and registers the delegated interaction listeners. Async
   loading keeps the schema fetches off the main thread so they never block
   the initial paint.
   Prefix: doc
   ============================================================================ */

/* Boots the reference page: collects the doc-ddl-root mounts and any inline
   editorial templates, then loads and renders every mount's schema in parallel,
   builds the flat or grouped object navigation from the combined result, and
   wires the delegated card, copy, and group-toggle listeners. Mounts with no
   data-schema attribute render an inline error and are skipped. */
async function doc_init() {
    var roots = doc_collectRoots();
    if (roots.length === 0) {
        return;
    }

    doc_collectTemplates();

    var renderPromises = [];
    for (var i = 0; i < roots.length; i++) {
        renderPromises.push(doc_renderRoot(roots[i]));
    }

    var results = await Promise.all(renderPromises);

    var groupSets = [];
    for (var r = 0; r < results.length; r++) {
        if (results[r]) {
            groupSets.push(results[r]);
        }
    }
    doc_buildNav(groupSets);
    doc_markLastSection();

    doc_bindInteractions();
}

/* ============================================================================
   FUNCTIONS: PAGE DISCOVERY
   ----------------------------------------------------------------------------
   The page-scan helpers run at boot before any schema loads: collecting the
   reference mounts on the page and gathering the inline editorial template
   fragments into the template store keyed by target object name and insertion
   slot.
   Prefix: doc
   ============================================================================ */

/* Returns the reference mounts on the page. */
function doc_collectRoots() {
    var roots = [];
    var nodes = document.querySelectorAll('.doc-ddl-root');
    for (var i = 0; i < nodes.length; i++) {
        roots.push(nodes[i]);
    }
    return roots;
}

/* Collects inline editorial template fragments into doc_templates, keyed by
   their target object name and then by their insertion slot, concatenating
   multiple fragments that target the same object and slot. */
function doc_collectTemplates() {
    doc_templates = {};
    var tpls = document.querySelectorAll('template[data-for]');
    for (var i = 0; i < tpls.length; i++) {
        var tpl = tpls[i];
        var objName = tpl.dataset.for;
        var section = tpl.dataset.section || 'after-all';
        if (!doc_templates[objName]) {
            doc_templates[objName] = {};
        }
        if (!doc_templates[objName][section]) {
            doc_templates[objName][section] = '';
        }
        doc_templates[objName][section] += tpl.innerHTML;
    }
}

/* ============================================================================
   FUNCTIONS: SCHEMA LOADING
   ----------------------------------------------------------------------------
   Schema loading and the per-mount render pass. Schema loading caches each
   parsed schema so a schema referenced by more than one mount is fetched once;
   the render pass resolves a mount's schema, applies its object and category
   filters, renders the object list into the mount, and returns the mount's
   navigation groups for the combined nav build.
   Prefix: doc
   ============================================================================ */

/* Loads a schema's JSON by name and caches it, returning the cached copy on a
   repeat request. Returns null and logs when the load fails so the caller can
   render an inline error. */
async function doc_loadSchema(name) {
    if (doc_schemaCache[name]) {
        return doc_schemaCache[name];
    }
    try {
        var data = await doc_fetchJson(doc_DATA_BASE_PATH + name + '.json');
        doc_schemaCache[name] = data;
        return data;
    } catch (err) {
        console.error('DDL Loader: Failed to load ' + name + '.json:', err);
        return null;
    }
}

/* Renders a single mount: resolves its schema, applies the explicit-object or
   category filter, renders the ordered object list into the mount, and returns
   the mount's navigation groups. Returns null when the mount lacks a schema or
   the schema fails to load, after rendering an inline error. */
async function doc_renderRoot(root) {
    var schemaName = root.dataset.schema;
    var explicitGroup = root.dataset.group || null;
    var explicitObjects = root.dataset.objects ?
        doc_splitList(root.dataset.objects) : [];
    var categoryFilter = root.dataset.category ?
        doc_splitList(root.dataset.category) : [];

    if (!schemaName) {
        root.innerHTML = '<p class="doc-obj-load-error">' +
            'Error: data-schema attribute is required on .doc-ddl-root</p>';
        return null;
    }

    var data = await doc_loadSchema(schemaName);
    if (!data) {
        root.innerHTML = '<p class="doc-obj-load-error">' +
            'Error: Could not load ' + doc_esc(schemaName) + '.json</p>';
        return null;
    }

    if (explicitObjects.length > 0) {
        doc_renderSchema(root, data, explicitObjects, schemaName);

        var typeMap = doc_buildTypeMap(data);
        var objects = [];
        for (var i = 0; i < explicitObjects.length; i++) {
            objects.push({
                name: explicitObjects[i],
                type: typeMap[explicitObjects[i]] || 'script',
                category: null
            });
        }
        return [{
            groupName: explicitGroup || schemaName,
            objects: objects
        }];
    }

    var allObjects = doc_getAllObjectsWithCategory(data);

    if (categoryFilter.length > 0) {
        allObjects = doc_filterByCategory(allObjects, categoryFilter);
    }

    var categoryGroups = doc_groupByCategory(allObjects);

    var orderedNames = [];
    for (var g = 0; g < categoryGroups.length; g++) {
        var groupObjects = categoryGroups[g].objects;
        for (var o = 0; o < groupObjects.length; o++) {
            orderedNames.push(groupObjects[o].name);
        }
    }
    doc_renderSchema(root, data, orderedNames, schemaName);

    if (explicitGroup) {
        return [{
            groupName: explicitGroup,
            objects: allObjects
        }];
    }

    return categoryGroups;
}

/* ============================================================================
   FUNCTIONS: OBJECT DISCOVERY AND GROUPING
   ----------------------------------------------------------------------------
   The object-set helpers that turn a parsed schema into an ordered, grouped
   object list: extraction of every object with its kind and category, the
   kind-then-name sort, the category filter, the category grouping, and the
   decision of whether the navigation should group by category at all.
   Prefix: doc
   ============================================================================ */

/* Extracts every object from a schema with its kind and category attached,
   sorted by kind display order and then alphabetically within each kind. */
function doc_getAllObjectsWithCategory(data) {
    var objects = [];
    var arrayKeys = Object.keys(doc_typeMap);
    for (var k = 0; k < arrayKeys.length; k++) {
        var arrayKey = arrayKeys[k];
        var typeName = doc_typeMap[arrayKey];
        var items = data[arrayKey] || [];
        for (var i = 0; i < items.length; i++) {
            objects.push({
                name: items[i].name,
                type: typeName,
                category: items[i].category || null,
                obj: items[i]
            });
        }
    }

    objects.sort(function (a, b) {
        var aIdx = doc_typeOrder.indexOf(a.type);
        var bIdx = doc_typeOrder.indexOf(b.type);
        if (aIdx !== bIdx) {
            return aIdx - bIdx;
        }
        return a.name.localeCompare(b.name);
    });

    return objects;
}

/* Restricts an object list to those whose category is in the supplied filter. */
function doc_filterByCategory(objects, categoryFilter) {
    var kept = [];
    for (var i = 0; i < objects.length; i++) {
        var o = objects[i];
        if (o.category && categoryFilter.indexOf(o.category) !== -1) {
            kept.push(o);
        }
    }
    return kept;
}

/* Groups objects by category in first-seen order, returning a list of
   { groupName, objects }. Uncategorized objects collect into an Other group. */
function doc_groupByCategory(objects) {
    var groups = {};
    var groupOrder = [];

    for (var i = 0; i < objects.length; i++) {
        var cat = objects[i].category || '_uncategorized';
        if (!groups[cat]) {
            groups[cat] = [];
            groupOrder.push(cat);
        }
        groups[cat].push(objects[i]);
    }

    var result = [];
    for (var g = 0; g < groupOrder.length; g++) {
        var key = groupOrder[g];
        result.push({
            groupName: key === '_uncategorized' ? 'Other' : key,
            objects: groups[key]
        });
    }
    return result;
}

/* Reports whether the navigation should group by category, which it does only
   when more than one distinct category appears across all mounts. */
function doc_shouldUseGroupedNav(groupSets) {
    var names = {};
    var count = 0;
    for (var s = 0; s < groupSets.length; s++) {
        var groups = groupSets[s];
        for (var g = 0; g < groups.length; g++) {
            var name = groups[g].groupName;
            if (!names[name]) {
                names[name] = true;
                count++;
            }
        }
    }
    return count > 1;
}

/* ============================================================================
   FUNCTIONS: SCHEMA RENDERING
   ----------------------------------------------------------------------------
   The render dispatcher that walks a mount's ordered object list, looks each
   name up across the schema's kind maps, and appends the matching object's
   rendered markup with a separator between objects. Names that match no schema
   object but carry an editorial template render from the template alone.
   Prefix: doc
   ============================================================================ */

/* Renders an ordered object list into a mount: builds the per-kind lookup maps,
   defaults to every object when the list is empty, then appends each object's
   markup separated by a hairline rule. */
function doc_renderSchema(container, data, objectList, schemaName) {
    var maps = doc_buildKindMaps(data);

    if (objectList.length === 0) {
        objectList = doc_collectAllNames(data);
    }

    var html = '';
    var isFirst = true;
    for (var i = 0; i < objectList.length; i++) {
        var objName = objectList[i];
        var separator = isFirst ? '' : '<hr class="doc-object-separator">';
        var editorial = doc_templates[objName];
        var rendered = doc_renderObject(objName, maps, editorial, schemaName);
        if (rendered) {
            html += separator + rendered;
            isFirst = false;
        }
    }

    container.innerHTML = html;
}

/* Marks the final rendered object section on the page so it reserves enough
   height for its jump-link to land at the top of the scroll region. */
function doc_markLastSection() {
    var sections = document.querySelectorAll('.doc-section');
    if (sections.length > 0) {
        sections[sections.length - 1].classList.add('doc-section-last');
    }
}

/* Builds the per-kind name-to-object lookup maps for a schema. */
function doc_buildKindMaps(data) {
    var maps = {
        table: {}, proc: {}, trigger: {}, function: {},
        view: {}, script: {}, xe: {}, ddltrigger: {}
    };
    doc_indexInto(maps.table, data.tables);
    doc_indexInto(maps.proc, data.procedures);
    doc_indexInto(maps.trigger, data.triggers);
    doc_indexInto(maps.function, data.functions);
    doc_indexInto(maps.view, data.views);
    doc_indexInto(maps.script, data.scripts);
    doc_indexInto(maps.xe, data.xeSessions);
    doc_indexInto(maps.ddltrigger, data.ddlTriggers);
    return maps;
}

/* Indexes a kind's object array into a name-keyed map. */
function doc_indexInto(map, items) {
    var list = items || [];
    for (var i = 0; i < list.length; i++) {
        map[list[i].name] = list[i];
    }
}

/* Returns every object name across all kinds in the schema, in kind order. */
function doc_collectAllNames(data) {
    var names = [];
    var arrayKeys = Object.keys(doc_typeMap);
    for (var k = 0; k < arrayKeys.length; k++) {
        var items = data[arrayKeys[k]] || [];
        for (var i = 0; i < items.length; i++) {
            names.push(items[i].name);
        }
    }
    return names;
}

/* Renders a single named object by dispatching to the matching kind renderer,
   or to the template-only renderer when the name has editorial content but no
   schema object. Returns an empty string when the name resolves to nothing. */
function doc_renderObject(objName, maps, editorial, schemaName) {
    if (maps.table[objName]) {
        return doc_renderTable(maps.table[objName], editorial, schemaName);
    }
    if (maps.proc[objName]) {
        return doc_renderProcedure(maps.proc[objName], editorial, schemaName);
    }
    if (maps.trigger[objName]) {
        return doc_renderTrigger(maps.trigger[objName], editorial, schemaName);
    }
    if (maps.function[objName]) {
        return doc_renderFunction(maps.function[objName], editorial, schemaName);
    }
    if (maps.view[objName]) {
        return doc_renderView(maps.view[objName], editorial, schemaName);
    }
    if (maps.script[objName]) {
        return doc_renderScript(maps.script[objName], editorial, schemaName);
    }
    if (maps.xe[objName]) {
        return doc_renderXESession(maps.xe[objName], editorial, schemaName);
    }
    if (maps.ddltrigger[objName]) {
        return doc_renderDDLTrigger(maps.ddltrigger[objName], editorial, schemaName);
    }
    if (editorial) {
        return doc_renderTemplateOnly(objName, editorial);
    }
    return '';
}

/* ============================================================================
   FUNCTIONS: OBJECT RENDERERS
   ----------------------------------------------------------------------------
   One renderer per object kind. Each opens the object section and header with
   its kind badge, renders the description and optional data-flow blurb, then
   stacks the kind's detail groups into cards. The shared section open, header,
   description, and data-flow markup are factored into helpers the renderers
   call so each renderer expresses only its kind-specific card set.
   Prefix: doc
   ============================================================================ */

/* Opens an object section and its block wrapper for the given anchor. */
function doc_openObjectSection(anchor) {
    return '<div class="doc-section" id="' + anchor + '">' +
           '<div class="doc-object-block">';
}

/* Builds an object heading with the object name and its kind badge. */
function doc_objectHeading(name, badgeClass, badgeLabel) {
    return '<h2>' + doc_esc(name) +
           ' <span class="doc-obj-badge ' + badgeClass + '">' + badgeLabel +
           '</span></h2>';
}

/* Builds the object description blurb when a description is present. */
function doc_objectDescription(description) {
    if (!description) {
        return '';
    }
    return '<p class="doc-obj-desc">' + doc_esc(description) + '</p>';
}

/* Builds the always-visible data-flow blurb when a data flow is present. */
function doc_objectDataFlow(dataFlow) {
    if (!dataFlow) {
        return '';
    }
    return '<div class="doc-enrichment-data-flow">' +
           '<h3>Data Flow</h3>' +
           '<p class="doc-data-flow-text">' + doc_esc(dataFlow) + '</p>' +
           '</div>';
}

/* Builds the muted module-and-category line shown under an object heading,
   emitting whichever of the two values is present and nothing when neither is. */
function doc_objectMeta(module, category) {
    var parts = [];
    if (module) {
        parts.push('Module: ' + doc_esc(module));
    }
    if (category) {
        parts.push('Category: ' + doc_esc(category));
    }
    if (parts.length === 0) {
        return '';
    }
    return '<p class="doc-muted">' + parts.join(' | ') + '</p>';
}

/* Appends an editorial fragment for the given slot when one exists. */
function doc_editorialSlot(editorial, slot) {
    if (editorial && editorial[slot]) {
        return editorial[slot];
    }
    return '';
}

/* Renders a table object: module line, description, data flow, then cards for
   fields, indexes, check constraints, foreign keys, design notes, status values,
   relationships, and queries, honoring editorial insertion slots throughout. */
function doc_renderTable(table, editorial, schemaName) {
    editorial = editorial || {};
    var anchor = doc_toAnchor(table.name);

    var html = doc_openObjectSection(anchor);
    html += doc_objectHeading(table.name, 'doc-badge-table', 'Table');
    html += doc_objectMeta(table.module, table.category);
    html += doc_objectDescription(table.description);
    html += doc_objectDataFlow(table.dataFlow);
    html += doc_editorialSlot(editorial, 'after-description');

    html += '<div class="doc-card-stack">';

    var columns = table.columns || [];
    if (columns.length > 0) {
        var fieldsHtml = doc_columnsTable(columns);
        fieldsHtml += doc_editorialSlot(editorial, 'after-fields');
        html += doc_buildCard('Fields', columns.length, fieldsHtml, anchor);
    }

    var indexes = table.indexes || [];
    if (indexes.length > 0) {
        var idxHtml = doc_indexesTable(indexes);
        idxHtml += doc_editorialSlot(editorial, 'after-indexes');
        html += doc_buildCard('Indexes', indexes.length, idxHtml, anchor);
    }

    var checks = table.checkConstraints || [];
    if (checks.length > 0) {
        html += doc_buildCard('Check Constraints', checks.length,
            doc_checksTable(checks), anchor);
    }

    var fks = table.foreignKeys || [];
    if (fks.length > 0) {
        html += doc_buildCard('Foreign Keys', fks.length,
            doc_foreignKeysTable(fks), anchor);
    }

    html += doc_editorialSlot(editorial, 'after-constraints');

    html += doc_enrichmentCards(table, anchor);

    html += doc_editorialSlot(editorial, 'after-enrichment');
    html += '</div>';
    html += doc_editorialSlot(editorial, 'after-all');
    html += '</div></div>';
    return html;
}

/* Renders a procedure object: module line, description, data flow, a parameters
   card or a no-parameters note, then the shared enrichment cards (design notes,
   status values, relationships, and common queries). */
function doc_renderProcedure(proc, editorial, schemaName) {
    editorial = editorial || {};
    var anchor = doc_toAnchor(proc.name);

    var html = doc_openObjectSection(anchor);
    html += doc_objectHeading(proc.name, 'doc-badge-proc', 'Procedure');
    html += doc_objectMeta(proc.module, proc.category);
    html += doc_objectDescription(proc.description);
    html += doc_objectDataFlow(proc.dataFlow);
    html += doc_editorialSlot(editorial, 'after-description');

    html += '<div class="doc-card-stack">';

    var params = proc.parameters || [];
    if (params.length > 0) {
        html += doc_buildCard('Parameters', params.length,
            doc_parametersTable(params), anchor);
    } else {
        html += '<p class="doc-muted">No parameters.</p>';
    }

    html += doc_editorialSlot(editorial, 'after-fields');

    html += doc_enrichmentCards(proc, anchor);

    html += '</div>';
    html += doc_editorialSlot(editorial, 'after-all');
    html += '</div></div>';
    return html;
}

/* Renders a trigger object: module line, description, data flow, then a behavior
   card describing its parent table, firing events, and enabled state, plus the
   shared enrichment cards (design notes, status values, relationships, and
   common queries). */
function doc_renderTrigger(trigger, editorial, schemaName) {
    editorial = editorial || {};
    var anchor = doc_toAnchor(trigger.name);

    var html = doc_openObjectSection(anchor);
    html += doc_objectHeading(trigger.name, 'doc-badge-trigger', 'Trigger');
    html += doc_objectMeta(trigger.module, trigger.category);
    html += doc_objectDescription(trigger.description);
    html += doc_objectDataFlow(trigger.dataFlow);
    html += doc_editorialSlot(editorial, 'after-description');

    html += '<div class="doc-card-stack">';
    html += doc_buildCard('Behavior', null, doc_triggerBehaviorTable(trigger), anchor);
    html += doc_editorialSlot(editorial, 'after-fields');

    html += doc_enrichmentCards(trigger, anchor);

    html += '</div>';
    html += doc_editorialSlot(editorial, 'after-all');
    html += '</div></div>';
    return html;
}

/* Renders a function object: module line, description, data flow, function-type
   note, a parameters card when the function declares parameters, then the shared
   enrichment cards (design notes, status values, relationships, and common
   queries). */
function doc_renderFunction(func, editorial, schemaName) {
    editorial = editorial || {};
    var anchor = doc_toAnchor(func.name);

    var html = doc_openObjectSection(anchor);
    html += doc_objectHeading(func.name, 'doc-badge-proc', 'Function');
    html += doc_objectMeta(func.module, func.category);
    html += doc_objectDescription(func.description);
    html += doc_objectDataFlow(func.dataFlow);
    html += '<p class="doc-muted">Type: ' + doc_esc(func.functionType) + '</p>';
    html += doc_editorialSlot(editorial, 'after-description');

    html += '<div class="doc-card-stack">';

    var params = func.parameters || [];
    if (params.length > 0) {
        html += doc_buildCard('Parameters', params.length,
            doc_parametersTable(params), anchor);
    }

    html += doc_editorialSlot(editorial, 'after-fields');

    html += doc_enrichmentCards(func, anchor);

    html += '</div>';
    html += doc_editorialSlot(editorial, 'after-all');
    html += '</div></div>';
    return html;
}

/* Renders a view object: module line, description, data flow, a columns card
   when the view declares columns, then the shared enrichment cards (design
   notes, status values, relationships, and common queries). */
function doc_renderView(view, editorial, schemaName) {
    editorial = editorial || {};
    var anchor = doc_toAnchor(view.name);

    var html = doc_openObjectSection(anchor);
    html += doc_objectHeading(view.name, 'doc-badge-table', 'View');
    html += doc_objectMeta(view.module, view.category);
    html += doc_objectDescription(view.description);
    html += doc_objectDataFlow(view.dataFlow);
    html += doc_editorialSlot(editorial, 'after-description');

    html += '<div class="doc-card-stack">';

    var columns = view.columns || [];
    if (columns.length > 0) {
        html += doc_buildCard('Columns', columns.length,
            doc_viewColumnsTable(columns), anchor);
    }

    html += doc_editorialSlot(editorial, 'after-fields');

    html += doc_enrichmentCards(view, anchor);

    html += '</div>';
    html += doc_editorialSlot(editorial, 'after-all');
    html += '</div></div>';
    return html;
}

/* Renders a script object: module line, description, data flow, then the shared
   enrichment cards (design notes, status values, relationships, and common
   queries). */
function doc_renderScript(script, editorial, schemaName) {
    editorial = editorial || {};
    var anchor = doc_toAnchor(script.name);

    var html = doc_openObjectSection(anchor);
    html += doc_objectHeading(script.name, 'doc-badge-script', 'Script');
    html += doc_objectMeta(script.module, script.category);
    html += doc_objectDescription(script.description);
    html += doc_objectDataFlow(script.dataFlow);
    html += doc_editorialSlot(editorial, 'after-description');

    html += '<div class="doc-card-stack">';

    html += doc_enrichmentCards(script, anchor);

    html += '</div>';
    html += doc_editorialSlot(editorial, 'after-fields');
    html += doc_editorialSlot(editorial, 'after-all');
    html += '</div></div>';
    return html;
}

/* Renders an extended-events session object: module line, description, data
   flow, then the shared enrichment cards (design notes, status values,
   relationships, and common queries). */
function doc_renderXESession(xe, editorial, schemaName) {
    editorial = editorial || {};
    var anchor = doc_toAnchor(xe.name);

    var html = doc_openObjectSection(anchor);
    html += doc_objectHeading(xe.name, 'doc-badge-xe', 'XE Session');
    html += doc_objectMeta(xe.module, xe.category);
    html += doc_objectDescription(xe.description);
    html += doc_objectDataFlow(xe.dataFlow);
    html += doc_editorialSlot(editorial, 'after-description');

    html += '<div class="doc-card-stack">';

    html += doc_enrichmentCards(xe, anchor);

    html += '</div>';
    html += doc_editorialSlot(editorial, 'after-fields');
    html += doc_editorialSlot(editorial, 'after-all');
    html += '</div></div>';
    return html;
}

/* Renders a DDL trigger object: module line, description, data flow, then the
   shared enrichment cards (design notes, status values, relationships, and
   common queries). */
function doc_renderDDLTrigger(ddl, editorial, schemaName) {
    editorial = editorial || {};
    var anchor = doc_toAnchor(ddl.name);

    var html = doc_openObjectSection(anchor);
    html += doc_objectHeading(ddl.name, 'doc-badge-ddltrigger', 'DDL Trigger');
    html += doc_objectMeta(ddl.module, ddl.category);
    html += doc_objectDescription(ddl.description);
    html += doc_objectDataFlow(ddl.dataFlow);
    html += doc_editorialSlot(editorial, 'after-description');

    html += '<div class="doc-card-stack">';

    html += doc_enrichmentCards(ddl, anchor);

    html += '</div>';
    html += doc_editorialSlot(editorial, 'after-fields');
    html += doc_editorialSlot(editorial, 'after-all');
    html += '</div></div>';
    return html;
}

/* Renders an object that has editorial content but no schema definition,
   emitting only the heading and whichever editorial slots are present. */
function doc_renderTemplateOnly(name, editorial) {
    editorial = editorial || {};
    var anchor = doc_toAnchor(name);

    var tpl = document.querySelector('template[data-for="' + name + '"]');
    var objType = tpl ? (tpl.dataset.type || 'script') : 'script';
    var badgeClass = 'doc-badge-' + objType;
    var badgeLabel = objType.charAt(0).toUpperCase() + objType.slice(1);

    var html = doc_openObjectSection(anchor);
    html += doc_objectHeading(name, badgeClass, badgeLabel);
    html += doc_editorialSlot(editorial, 'after-description');
    html += doc_editorialSlot(editorial, 'after-fields');
    html += doc_editorialSlot(editorial, 'after-indexes');
    html += doc_editorialSlot(editorial, 'after-constraints');
    html += doc_editorialSlot(editorial, 'after-enrichment');
    html += doc_editorialSlot(editorial, 'after-all');
    html += '</div></div>';
    return html;
}

/* ============================================================================
   FUNCTIONS: CARD BUILDER
   ----------------------------------------------------------------------------
   The card builder and the detail-group table and content builders the object
   renderers compose. The card builder wraps a label, optional count, and
   content body in a collapsible toggle-and-panel card; the detail builders turn
   a kind's data arrays into field tables and enrichment markup.
   Prefix: doc
   ============================================================================ */

/* Wraps a labeled, optionally counted content body in a collapsible card,
   opening it by default when its label is in the default-open set. */
function doc_buildCard(label, count, contentHtml, anchor) {
    var cardId = anchor + '-card-' +
        label.toLowerCase().replace(/\s+/g, '-');
    var isDefault = doc_defaultOpenCards.indexOf(label) !== -1;
    var openClass = isDefault ? ' doc-card-open' : '';

    var html = '<div class="doc-card-item">';
    html += '<button class="doc-card-toggle' + openClass +
        '" data-card-target="' + cardId + '">';
    html += '<span class="doc-card-arrow' + openClass + '">&#9654;</span>';
    html += '<span class="doc-card-label">' + doc_esc(label) + '</span>';
    if (count !== null && count !== undefined) {
        html += '<span class="doc-card-count">' + count + '</span>';
    }
    html += '</button>';
    html += '<div class="doc-card-content' + openClass + '" id="' + cardId +
        '">' + contentHtml + '</div>';
    html += '</div>';
    return html;
}

/* Builds the shared enrichment card set (design notes, status values,
   relationships, and common queries) for any object that carries them, in a
   fixed order, emitting only the cards whose data is present. */
function doc_enrichmentCards(obj, anchor) {
    var html = '';

    var designNotes = obj.designNotes || [];
    if (designNotes.length > 0) {
        html += doc_buildCard('Design Notes', designNotes.length,
            doc_designNotesHtml(designNotes), anchor);
    }

    var statusValues = obj.statusValues || [];
    if (statusValues.length > 0) {
        html += doc_buildCard('Status Values', statusValues.length,
            doc_statusValuesHtml(statusValues), anchor);
    }

    var relNotes = obj.relationshipNotes || [];
    if (relNotes.length > 0) {
        html += doc_buildCard('Relationships', relNotes.length,
            doc_relationshipNotesHtml(relNotes), anchor);
    }

    var queries = obj.queries || [];
    if (queries.length > 0) {
        html += doc_buildCard('Common Queries', queries.length,
            doc_queriesHtml(queries, anchor), anchor);
    }

    return html;
}

/* Builds the columns field table for a table object. */
function doc_columnsTable(columns) {
    var html = '<table class="doc-field-table doc-card-field-table">';
    html += '<thead><tr>' +
        '<th class="doc-field-table-th">Column</th>' +
        '<th class="doc-field-table-th">Type</th>' +
        '<th class="doc-field-table-th">Null</th>' +
        '<th class="doc-field-table-th">Default</th>' +
        '<th class="doc-field-table-th">Description</th></tr></thead>';
    html += '<tbody>';
    for (var i = 0; i < columns.length; i++) {
        var col = columns[i];
        var typeName = doc_formatType(col);
        var nullable = col.nullable ? 'Yes' : 'No';
        var defaultVal = doc_formatDefault(col);
        var desc = col.description ? doc_esc(col.description) : '';
        html += '<tr>' +
            '<td class="doc-field-table-td doc-card-field-table-td doc-field-table-td-name doc-card-field-table-td-name">' + doc_esc(col.name) + '</td>' +
            '<td class="doc-field-table-td doc-card-field-table-td doc-field-table-td-type">' + doc_esc(typeName) + '</td>' +
            '<td class="doc-field-table-td doc-card-field-table-td">' + nullable + '</td>' +
            '<td class="doc-field-table-td doc-card-field-table-td">' + doc_esc(defaultVal) + '</td>' +
            '<td class="doc-field-table-td doc-card-field-table-td">' + desc + '</td></tr>';
    }
    html += '</tbody></table>';
    return html;
}

/* Builds the indexes field table for a table object. */
function doc_indexesTable(indexes) {
    var html = '<table class="doc-field-table doc-card-field-table">';
    html += '<thead><tr>' +
        '<th class="doc-field-table-th">Name</th>' +
        '<th class="doc-field-table-th">Type</th>' +
        '<th class="doc-field-table-th">Key Columns</th>' +
        '<th class="doc-field-table-th">Included</th></tr></thead>';
    html += '<tbody>';
    for (var i = 0; i < indexes.length; i++) {
        var idx = indexes[i];
        var typeBadge = idx.isPrimaryKey ? 'PK' :
            idx.isUniqueConstraint ? 'UQ' :
            idx.isUnique ? 'Unique' : idx.type;
        html += '<tr>' +
            '<td class="doc-field-table-td doc-card-field-table-td doc-field-table-td-name doc-card-field-table-td-name">' + doc_esc(idx.name) + '</td>' +
            '<td class="doc-field-table-td doc-card-field-table-td">' + doc_esc(typeBadge) + '</td>' +
            '<td class="doc-field-table-td doc-card-field-table-td">' + doc_esc(idx.keyColumns || '') + '</td>' +
            '<td class="doc-field-table-td doc-card-field-table-td">' + doc_esc(idx.includedColumns || '\u2014') + '</td></tr>';
    }
    html += '</tbody></table>';
    return html;
}

/* Builds the check-constraints field table for a table object. */
function doc_checksTable(checks) {
    var html = '<table class="doc-field-table doc-card-field-table">';
    html += '<thead><tr>' +
        '<th class="doc-field-table-th">Name</th>' +
        '<th class="doc-field-table-th">Definition</th></tr></thead>';
    html += '<tbody>';
    for (var i = 0; i < checks.length; i++) {
        var ck = checks[i];
        html += '<tr>' +
            '<td class="doc-field-table-td doc-card-field-table-td doc-field-table-td-name doc-card-field-table-td-name">' + doc_esc(ck.name) + '</td>' +
            '<td class="doc-field-table-td doc-card-field-table-td"><code>' + doc_esc(ck.definition) + '</code></td></tr>';
    }
    html += '</tbody></table>';
    return html;
}

/* Builds the foreign-keys field table for a table object. */
function doc_foreignKeysTable(fks) {
    var html = '<table class="doc-field-table doc-card-field-table">';
    html += '<thead><tr>' +
        '<th class="doc-field-table-th">Name</th>' +
        '<th class="doc-field-table-th">Column</th>' +
        '<th class="doc-field-table-th">References</th></tr></thead>';
    html += '<tbody>';
    for (var i = 0; i < fks.length; i++) {
        var fk = fks[i];
        var refTarget = fk.referencedTable + '.' + fk.referencedColumn;
        html += '<tr>' +
            '<td class="doc-field-table-td doc-card-field-table-td doc-field-table-td-name doc-card-field-table-td-name">' + doc_esc(fk.name) + '</td>' +
            '<td class="doc-field-table-td doc-card-field-table-td">' + doc_esc(fk.column) + '</td>' +
            '<td class="doc-field-table-td doc-card-field-table-td">' + doc_esc(refTarget) + '</td></tr>';
    }
    html += '</tbody></table>';
    return html;
}

/* Builds the parameters field table for a procedure or function object. */
function doc_parametersTable(params) {
    var html = '<table class="doc-field-table doc-card-field-table">';
    html += '<thead><tr>' +
        '<th class="doc-field-table-th">Parameter</th>' +
        '<th class="doc-field-table-th">Type</th>' +
        '<th class="doc-field-table-th">Direction</th>' +
        '<th class="doc-field-table-th">Required</th></tr></thead>';
    html += '<tbody>';
    for (var i = 0; i < params.length; i++) {
        var p = params[i];
        var typeName = doc_formatParamType(p);
        var direction = p.isOutput ? 'OUTPUT' : 'INPUT';
        var required = p.isOptional ? 'Optional' : 'Required';
        html += '<tr>' +
            '<td class="doc-field-table-td doc-card-field-table-td doc-field-table-td-name doc-card-field-table-td-name">' + doc_esc(p.name) + '</td>' +
            '<td class="doc-field-table-td doc-card-field-table-td doc-field-table-td-type">' + doc_esc(typeName) + '</td>' +
            '<td class="doc-field-table-td doc-card-field-table-td">' + direction + '</td>' +
            '<td class="doc-field-table-td doc-card-field-table-td">' + required + '</td></tr>';
    }
    html += '</tbody></table>';
    return html;
}

/* Builds the columns field table for a view object. */
function doc_viewColumnsTable(columns) {
    var html = '<table class="doc-field-table doc-card-field-table">';
    html += '<thead><tr>' +
        '<th class="doc-field-table-th">Column</th>' +
        '<th class="doc-field-table-th">Type</th>' +
        '<th class="doc-field-table-th">Nullable</th></tr></thead>';
    html += '<tbody>';
    for (var i = 0; i < columns.length; i++) {
        var col = columns[i];
        var typeName = doc_formatType(col);
        html += '<tr>' +
            '<td class="doc-field-table-td doc-card-field-table-td doc-field-table-td-name doc-card-field-table-td-name">' + doc_esc(col.name) + '</td>' +
            '<td class="doc-field-table-td doc-card-field-table-td doc-field-table-td-type">' + doc_esc(typeName) + '</td>' +
            '<td class="doc-field-table-td doc-card-field-table-td">' + (col.nullable ? 'Yes' : 'No') + '</td></tr>';
    }
    html += '</tbody></table>';
    return html;
}

/* Builds the behavior field table for a trigger object. */
function doc_triggerBehaviorTable(trigger) {
    var events = [];
    if (trigger.firesOnInsert) {
        events.push('INSERT');
    }
    if (trigger.firesOnUpdate) {
        events.push('UPDATE');
    }
    if (trigger.firesOnDelete) {
        events.push('DELETE');
    }

    var html = '<table class="doc-field-table doc-card-field-table">';
    html += '<thead><tr>' +
        '<th class="doc-field-table-th">Aspect</th>' +
        '<th class="doc-field-table-th">Detail</th></tr></thead>';
    html += '<tbody>';
    html += '<tr><td class="doc-field-table-td doc-card-field-table-td">Parent Table</td>' +
        '<td class="doc-field-table-td doc-card-field-table-td">' + doc_esc(trigger.parentTable) + '</td></tr>';
    html += '<tr><td class="doc-field-table-td doc-card-field-table-td">Fires On</td>' +
        '<td class="doc-field-table-td doc-card-field-table-td">AFTER ' + events.join(', ') + '</td></tr>';
    html += '<tr><td class="doc-field-table-td doc-card-field-table-td">Status</td>' +
        '<td class="doc-field-table-td doc-card-field-table-td">' + (trigger.isEnabled ? 'Enabled' : 'Disabled') + '</td></tr>';
    html += '</tbody></table>';
    return html;
}

/* Builds the design-notes content block for a card. */
function doc_designNotesHtml(designNotes) {
    var html = '';
    for (var i = 0; i < designNotes.length; i++) {
        var note = designNotes[i];
        html += '<div class="doc-design-note">';
        html += '<h4 class="doc-design-note-title">' + doc_esc(note.topic) + '</h4>';
        if (note.summary) {
            html += '<p class="doc-design-note-summary">' + doc_esc(note.summary) + '</p>';
        }
        html += '<p class="doc-design-note-body">' + doc_esc(note.note) + '</p>';
        html += '</div>';
    }
    return html;
}

/* Builds the relationship-notes content block for a card. */
function doc_relationshipNotesHtml(relNotes) {
    var html = '';
    for (var i = 0; i < relNotes.length; i++) {
        var rel = relNotes[i];
        html += '<div class="doc-relationship-note">';
        html += '<h4 class="doc-relationship-note-title">' + doc_esc(rel.relatedObject) + '</h4>';
        html += '<p class="doc-relationship-note-body">' + doc_esc(rel.note) + '</p>';
        html += '</div>';
    }
    return html;
}

/* Builds the status-values content block for a card, grouping value rows under
   a per-column label and table. */
function doc_statusValuesHtml(statusValues) {
    var byColumn = {};
    var columnOrder = [];
    for (var i = 0; i < statusValues.length; i++) {
        var sv = statusValues[i];
        var col = sv.column || 'General';
        if (!byColumn[col]) {
            byColumn[col] = [];
            columnOrder.push(col);
        }
        byColumn[col].push(sv);
    }

    var html = '';
    for (var c = 0; c < columnOrder.length; c++) {
        var colName = columnOrder[c];
        var values = byColumn[colName];
        html += '<p class="doc-status-column-label">Applies to: ' +
            '<code class="doc-status-column-label-code">' + doc_esc(colName) + '</code></p>';
        html += '<table class="doc-field-table doc-card-field-table">';
        html += '<thead><tr>' +
            '<th class="doc-field-table-th doc-status-table-th-value">Value</th>' +
            '<th class="doc-field-table-th">Meaning</th></tr></thead>';
        html += '<tbody>';
        for (var v = 0; v < values.length; v++) {
            html += '<tr>' +
                '<td class="doc-field-table-td doc-card-field-table-td doc-status-table-td-value doc-card-field-table-td-name">' +
                '<code class="doc-status-table-td-value-code">' + doc_esc(values[v].value) + '</code></td>' +
                '<td class="doc-field-table-td doc-card-field-table-td">' + doc_esc(values[v].meaning) + '</td></tr>';
        }
        html += '</tbody></table>';
    }
    return html;
}

/* Builds the common-queries content block for a card, each with a description
   and a copyable code surface. */
function doc_queriesHtml(queries, anchor) {
    var html = '';
    for (var i = 0; i < queries.length; i++) {
        var q = queries[i];
        var queryId = anchor + '-query-' + i;
        html += '<div class="doc-query-block">';
        html += '<h4 class="doc-query-block-title">' + doc_esc(q.name) + '</h4>';
        if (q.description) {
            html += '<p class="doc-query-desc">' + doc_esc(q.description) + '</p>';
        }
        html += '<div class="doc-query-code-wrapper">';
        html += '<button class="doc-copy-btn" data-copy-target="' + queryId +
            '" title="Copy to clipboard">Copy</button>';
        html += '<pre class="doc-query-code" id="' + queryId +
            '"><code class="doc-query-code-text">' + doc_esc(q.sql) + '</code></pre>';
        html += '</div>';
        html += '</div>';
    }
    return html;
}

/* ============================================================================
   FUNCTIONS: OBJECT NAVIGATION
   ----------------------------------------------------------------------------
   The object jump-link navigation builders. The entry point chooses the flat
   or grouped form based on category spread, the flat builder lists every object
   as a jump link, and the grouped builder nests jump links under expandable
   category toggles that start expanded.
   Prefix: doc
   ============================================================================ */

/* Builds the object navigation into the header nav mount, choosing the grouped
   accordion when categories span more than one group and the flat list
   otherwise. */
function doc_buildNav(groupSets) {
    var container = document.querySelector('.doc-obj-nav');
    if (!container) {
        return;
    }

    if (doc_shouldUseGroupedNav(groupSets)) {
        var allGroups = [];
        for (var s = 0; s < groupSets.length; s++) {
            for (var g = 0; g < groupSets[s].length; g++) {
                allGroups.push(groupSets[s][g]);
            }
        }
        doc_buildGroupedNav(container, allGroups);
    } else {
        var allObjects = [];
        for (var gs = 0; gs < groupSets.length; gs++) {
            for (var gi = 0; gi < groupSets[gs].length; gi++) {
                var objs = groupSets[gs][gi].objects;
                for (var o = 0; o < objs.length; o++) {
                    allObjects.push(objs[o]);
                }
            }
        }
        doc_buildFlatNav(container, allObjects);
    }
}

/* Builds a flat list of object jump links into the nav container. */
function doc_buildFlatNav(container, objects) {
    var html = '';
    for (var i = 0; i < objects.length; i++) {
        html += doc_navLink(objects[i]);
    }
    container.innerHTML = html;
}

/* Builds a category-grouped accordion of object jump links into the nav
   container, with each category's items shown beneath an expandable header that
   starts expanded. */
function doc_buildGroupedNav(container, groups) {
    container.classList.add('doc-obj-nav-grouped');
    var html = '';
    for (var i = 0; i < groups.length; i++) {
        var group = groups[i];
        var groupId = 'doc-nav-group-' + i;
        var count = group.objects.length;
        var groupLabel = group.groupName || 'Objects';

        html += '<div class="doc-obj-nav-group">';
        html += '<button class="doc-obj-nav-group-toggle" data-nav-group-target="' +
            groupId + '" aria-expanded="true">';
        html += '<span class="doc-obj-nav-group-arrow">&#9660;</span> ';
        html += doc_esc(groupLabel) +
            ' <span class="doc-obj-nav-group-count">(' + count + ')</span>';
        html += '</button>';

        html += '<div class="doc-obj-nav-group-items" id="' + groupId + '">';
        for (var o = 0; o < group.objects.length; o++) {
            html += doc_navLink(group.objects[o]);
        }
        html += '</div></div>';
    }
    container.innerHTML = html;
}

/* Builds a single object jump link with its kind type label. */
function doc_navLink(obj) {
    var anchor = doc_toAnchor(obj.name);
    var label = doc_typeLabel(obj.type);
    var navClass = 'doc-nav-' + obj.type;
    return '<a class="doc-obj-nav-link" href="#' + anchor + '">' +
        doc_esc(obj.name) +
        ' <span class="doc-obj-type-label ' + navClass + '">' + label + '</span></a>';
}

/* ============================================================================
   FUNCTIONS: EVENT DELEGATION
   ----------------------------------------------------------------------------
   The delegated interaction listeners registered once during page boot: a body
   click dispatcher that toggles cards, copies query text, and expands or
   collapses nav category groups by examining the clicked element's closest
   matching control. Delegation keeps a single listener per concern regardless
   of how many objects render.
   Prefix: doc
   ============================================================================ */

/* Registers the delegated click dispatcher on the document body that routes
   card-toggle, copy-button, and nav-group-toggle clicks to their handlers. */
function doc_bindInteractions() {
    document.body.addEventListener('click', doc_onBodyClick);
}

/* Dispatches a body click to the card toggle, copy button, or nav group toggle
   whose control the click originated within, ignoring clicks elsewhere. */
function doc_onBodyClick(event) {
    var cardToggle = event.target.closest('.doc-card-toggle');
    if (cardToggle) {
        doc_toggleCard(cardToggle);
        return;
    }

    var copyBtn = event.target.closest('.doc-copy-btn');
    if (copyBtn) {
        doc_copyQuery(copyBtn);
        return;
    }

    var groupToggle = event.target.closest('.doc-obj-nav-group-toggle');
    if (groupToggle) {
        doc_toggleNavGroup(groupToggle);
        return;
    }
}

/* Toggles a card open or closed by flipping the open state on its toggle,
   arrow, and content panel. */
function doc_toggleCard(toggle) {
    var content = document.getElementById(toggle.dataset.cardTarget);
    var arrow = toggle.querySelector('.doc-card-arrow');
    var isOpen = toggle.classList.contains('doc-card-open');

    if (isOpen) {
        toggle.classList.remove('doc-card-open');
        if (arrow) {
            arrow.classList.remove('doc-card-open');
        }
        if (content) {
            content.classList.remove('doc-card-open');
        }
    } else {
        toggle.classList.add('doc-card-open');
        if (arrow) {
            arrow.classList.add('doc-card-open');
        }
        if (content) {
            content.classList.add('doc-card-open');
        }
    }
}

/* Copies a query's code text to the clipboard and flashes the button to
   confirm success or report failure, restoring its label after a delay. */
function doc_copyQuery(btn) {
    var codeBlock = document.getElementById(btn.dataset.copyTarget);
    if (!codeBlock) {
        return;
    }
    var text = codeBlock.textContent;
    navigator.clipboard.writeText(text).then(function () {
        btn.textContent = 'Copied!';
        btn.classList.add('doc-copy-success');
        setTimeout(function () {
            btn.textContent = 'Copy';
            btn.classList.remove('doc-copy-success');
        }, 2000);
    }).catch(function () {
        btn.textContent = 'Failed';
        setTimeout(function () {
            btn.textContent = 'Copy';
        }, 2000);
    });
}

/* Expands or collapses a nav category group by toggling the collapsed state on
   its items and flipping the header's expanded state and arrow glyph. */
function doc_toggleNavGroup(toggle) {
    var target = document.getElementById(toggle.dataset.navGroupTarget);
    var arrow = toggle.querySelector('.doc-obj-nav-group-arrow');
    var isExpanded = toggle.getAttribute('aria-expanded') === 'true';

    if (isExpanded) {
        if (target) {
            target.classList.add('doc-collapsed');
        }
        toggle.setAttribute('aria-expanded', 'false');
        if (arrow) {
            arrow.innerHTML = '&#9654;';
        }
    } else {
        if (target) {
            target.classList.remove('doc-collapsed');
        }
        toggle.setAttribute('aria-expanded', 'true');
        if (arrow) {
            arrow.innerHTML = '&#9660;';
        }
    }
}

/* ============================================================================
   FUNCTIONS: FORMATTING HELPERS
   ----------------------------------------------------------------------------
   The pure value-formatting helpers used by the renderers: splitting a
   comma-separated data attribute into trimmed tokens, building a name-to-kind
   map and the kind display label, formatting a column or parameter type, the
   default-value normalization, and the name-to-anchor slug.
   Prefix: doc
   ============================================================================ */

/* Splits a comma-separated attribute value into trimmed, non-empty tokens. */
function doc_splitList(value) {
    var parts = value.split(',');
    var out = [];
    for (var i = 0; i < parts.length; i++) {
        var trimmed = parts[i].trim();
        if (trimmed) {
            out.push(trimmed);
        }
    }
    return out;
}

/* Builds a name-to-kind map across every object in a schema, folding in any
   inline template-declared kinds for template-only objects. */
function doc_buildTypeMap(data) {
    var typeMap = {};
    var arrayKeys = Object.keys(doc_typeMap);
    for (var k = 0; k < arrayKeys.length; k++) {
        var arrayKey = arrayKeys[k];
        var typeName = doc_typeMap[arrayKey];
        var items = data[arrayKey] || [];
        for (var i = 0; i < items.length; i++) {
            typeMap[items[i].name] = typeName;
        }
    }

    var tpls = document.querySelectorAll('template[data-for]');
    for (var t = 0; t < tpls.length; t++) {
        var name = tpls[t].dataset.for;
        if (!typeMap[name] && tpls[t].dataset.type) {
            typeMap[name] = tpls[t].dataset.type;
        }
    }

    return typeMap;
}

/* Returns the short display label for an object kind. */
function doc_typeLabel(type) {
    if (type === 'proc') {
        return 'proc';
    }
    if (type === 'trigger') {
        return 'trigger';
    }
    if (type === 'function') {
        return 'func';
    }
    if (type === 'view') {
        return 'view';
    }
    if (type === 'script') {
        return 'script';
    }
    if (type === 'xe') {
        return 'xe';
    }
    if (type === 'ddltrigger') {
        return 'ddltrigger';
    }
    return 'table';
}

/* Formats a column's SQL type, appending a length qualifier when present. */
function doc_formatType(col) {
    var type = (col.dataType || '').toUpperCase();
    if (col.length) {
        type += '(' + col.length + ')';
    }
    return type;
}

/* Formats a parameter's SQL type, appending a length qualifier when present. */
function doc_formatParamType(param) {
    var type = (param.dataType || '').toUpperCase();
    if (param.length) {
        type += '(' + param.length + ')';
    }
    return type;
}

/* Normalizes a column's default value for display, stripping wrapping
   parentheses and upper-casing the recognized scalar functions. */
function doc_formatDefault(col) {
    if (col.identity) {
        return 'IDENTITY';
    }
    if (!col.default) {
        return '\u2014';
    }

    var val = col.default;
    while (val.charAt(0) === '(' && val.charAt(val.length - 1) === ')') {
        val = val.substring(1, val.length - 1);
    }
    var lower = val.toLowerCase();
    if (lower === 'getdate()') {
        return 'GETDATE()';
    }
    if (lower === 'suser_sname()') {
        return 'SUSER_SNAME()';
    }
    if (lower === 'newid()') {
        return 'NEWID()';
    }
    return val;
}

/* Converts an object name into a lowercase, hyphenated anchor slug, dropping a
   trailing .ps1 extension and splitting camel-case boundaries. */
function doc_toAnchor(name) {
    return name
        .replace(/\.ps1$/i, '')
        .replace(/([a-z])([A-Z])/g, '$1-$2')
        .replace(/_/g, '-')
        .replace(/\./g, '-')
        .toLowerCase();
}

/* Self-invokes the page boot once the DOM is parsed. */
document.addEventListener('DOMContentLoaded', doc_init);

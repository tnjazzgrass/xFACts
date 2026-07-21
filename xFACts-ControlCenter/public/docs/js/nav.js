/* ============================================================================
   xFACts Control Center - Documentation Site Navigation (nav.js)
   Location: E:\xFACts-ControlCenter\public\docs\js\nav.js
   Version: Tracked in dbo.System_Metadata (component: Documentation.Site)

   Builds and injects the documentation-site navigation chrome on every docs
   page: the sticky sidebar rail of modules from doc-registry.json, the current
   module's sub-page links injected into the fixed header, and the generated
   page footer. The active module expands inline to its sub-pages, discovered by
   HEAD-request existence check. The rail collapses to an icon strip, and that
   collapse state persists across pages via localStorage. nav.js loads on every
   page and owns its own registry fetch, so it stays self-contained. Falls back
   to a minimal hardcoded module set when doc-registry.json cannot be loaded.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: NAVIGATION DATA
   STATE: PAGE CONTEXT
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: PAGE DETECTION
   FUNCTIONS: NAV RENDERING
   FUNCTIONS: SUBPAGE DISCOVERY
   FUNCTIONS: COLLAPSE STATE
   ============================================================================ */

/* ============================================================================
   CONSTANTS: NAVIGATION DATA
   ----------------------------------------------------------------------------
   The ordered sub-page type table that drives sub-page link display order, the
   sub-page glyphs, the minimal fallback module set used only when the registry
   fails to load, and the localStorage key under which the rail collapse state
   is persisted.
   Prefix: doc
   ============================================================================ */

/* Sub-page types in nav display order. Named CC guide pages are handled
   separately and insert before the -arch entry using registry data. */
const doc_childTypes = [
    { suffix: '-cc',   folder: 'cc/',   label: 'Control Center', icon: '\u25A1' },
    { suffix: '-arch', folder: 'arch/', label: 'Architecture',   icon: '\u2318' },
    { suffix: '-ref',  folder: 'ref/',  label: 'Reference',      icon: '\u2263' }
];

/* Glyph shown beside the current module's own narrative (overview) link. */
const doc_overviewIcon = '\u25CB';

/* Minimal module set rendered only when doc-registry.json cannot be loaded. */
const doc_fallbackPages = [
    { pageId: 'index', title: 'xFACts Secrets Revealed', sortOrder: 0 },
    { pageId: 'engine-room', title: 'The Engine Room', sortOrder: 10 },
    { pageId: 'serverhealth', title: 'Server Health', sortOrder: 20 }
];

/* localStorage key under which the rail collapsed state persists across pages. */
const doc_collapseKey = 'docNavCollapsed';

/* ============================================================================
   STATE: PAGE CONTEXT
   ----------------------------------------------------------------------------
   Per-page location context derived from the current URL during init: the
   current filename, whether the page lives in a subfolder, and the relative
   path prefix used to resolve sibling pages.
   Prefix: doc
   ============================================================================ */

/* Current page filename, defaulting to index.html at a directory root. */
var doc_filename = 'index.html';

/* True when the current page lives in a cc/, arch/, ref/, or guides/ subfolder. */
var doc_isSubfolder = false;

/* Relative path prefix from the current page to the pages root. */
var doc_prefix = '';

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The page boot function: derives page context from the URL, applies the
   persisted collapse state, loads the documentation registry, and renders the
   navigation chrome. Async loading keeps the registry fetch off the main
   thread so it never blocks page paint.
   Prefix: doc
   ============================================================================ */

/* Boots the navigation: resolves page context from the URL, applies the
   persisted rail collapse state, then loads the registry asynchronously and
   renders the rail, header sub-page links, and footer. The fallback set renders
   only on a genuine load failure. */
async function doc_init() {
    var path = window.location.pathname;
    doc_filename = path.substring(path.lastIndexOf('/') + 1) || 'index.html';
    doc_isSubfolder = path.indexOf('/ref/') !== -1 ||
                      path.indexOf('/arch/') !== -1 ||
                      path.indexOf('/cc/') !== -1 ||
                      path.indexOf('/guides/') !== -1;
    doc_prefix = doc_isSubfolder ? '../' : '';

    doc_applyCollapse(doc_readCollapse());
    doc_bindToggle();

    var jsonPath = '/generated/ddl/doc-registry.json';
    try {
        var registry = await doc_fetchRegistry(jsonPath);
        var pages = doc_registryToPages(registry);
        doc_loadAndRender(pages);
    } catch (e) {
        doc_loadAndRender(doc_fallbackPages);
    }
}

/* ============================================================================
   FUNCTIONS: PAGE DETECTION
   ----------------------------------------------------------------------------
   Helpers that resolve the current page against the registry: the narrative
   filename for a pageId, the CC slug list for a page, which registry entry and
   sub-page type the current URL corresponds to, the registry fetch, and the
   sortOrder-ordered module extraction.
   Prefix: doc
   ============================================================================ */

/* Derives the narrative filename for a pageId. */
function doc_pageFile(pageId) {
    return pageId + '.html';
}

/* Returns the { slug, title } list for a page's sections that declare a CC
   slug, used to build named CC guide links. */
function doc_getCcSlugs(page) {
    var slugs = [];
    if (!page.sections) {
        return slugs;
    }
    for (var i = 0; i < page.sections.length; i++) {
        var s = page.sections[i];
        if (s.ccSlug) {
            slugs.push({ slug: s.ccSlug, title: s.ccTitle || s.ccSlug });
        }
    }
    return slugs;
}

/* Resolves the current URL to a registry page id and sub-page type. Named CC
   guide pages are matched before standard sub-page types because their
   filenames are more specific. A page that matches no registry entry (such as a
   standalone guide under guides/) returns a null id, which renders the full
   module rail with no active module and skips sub-page discovery. */
function doc_detectCurrent(pages) {
    for (var i = 0; i < pages.length; i++) {
        var p = pages[i];
        var narrative = doc_pageFile(p.pageId);

        if (doc_filename === narrative) {
            return { id: p.pageId, type: 'narrative' };
        }

        var slugs = doc_getCcSlugs(p);
        for (var s = 0; s < slugs.length; s++) {
            var namedCcFile = p.pageId + '-cc-' + slugs[s].slug + '.html';
            if (doc_filename === namedCcFile) {
                return { id: p.pageId, type: '-cc', slug: slugs[s].slug };
            }
        }

        for (var j = 0; j < doc_childTypes.length; j++) {
            var ct = doc_childTypes[j];
            var childFile = p.pageId + ct.suffix + '.html';
            if (doc_filename === childFile) {
                return { id: p.pageId, type: ct.suffix };
            }
        }
    }
    return { id: null, type: 'narrative' };
}

/* Fetches the documentation registry JSON and returns the parsed array. Throws
   on a non-OK response so doc_init's caller falls back to the minimal set. */
async function doc_fetchRegistry(url) {
    var response = await fetch(url);
    if (!response.ok) {
        throw new Error('HTTP ' + response.status + ' fetching ' + url);
    }
    return response.json();
}

/* Extracts the primary module rows (entries with a sortOrder) from the raw
   registry and returns them ordered by sortOrder. */
function doc_registryToPages(registry) {
    var pages = [];
    for (var i = 0; i < registry.length; i++) {
        var entry = registry[i];
        if (entry.sortOrder !== null && entry.sortOrder !== undefined) {
            pages.push(entry);
        }
    }
    pages.sort(function (a, b) { return a.sortOrder - b.sortOrder; });
    return pages;
}

/* ============================================================================
   FUNCTIONS: NAV RENDERING
   ----------------------------------------------------------------------------
   Builders that turn the resolved module set into chrome and inject it: the
   sidebar rail (head plus module list, with the active module expanded to its
   sub-pages), the header sub-page link row, the generated footer, and the hub
   card grid on the index page. The render entry point injects the rail and
   footer immediately, then triggers async sub-page discovery for the rail and
   the header link row.
   Prefix: doc
   ============================================================================ */

/* Returns 'doc-nav-collapsed' when the rail is currently collapsed, else an
   empty string, for appending to an element's class list during a build. */
function doc_collapsedClass() {
    return doc_isCollapsed() ? ' doc-nav-collapsed' : '';
}

/* Builds the sidebar rail markup for the module set: the brand-and-toggle head
   and the scrolling module list. The current module carries the active marker
   and, when its sub-pages are known, expands to show them. */
function doc_buildRail(pages, currentChildren) {
    var current = doc_detectCurrent(pages);
    var cc = doc_collapsedClass();

    var hubHref = doc_prefix + 'index.html';

    var html = '';
    html += '<div class="doc-nav-head' + cc + '">';
    html += '<a class="doc-nav-brand' + cc + '" href="' + hubHref + '" ' +
            'title="xFACts Secrets Revealed">';
    html += '<span class="doc-nav-brand-mark">\u2302</span>';
    html += '<span class="doc-nav-brand-text' + cc + '">xFACts Secrets Revealed</span>';
    html += '</a>';
    html += '<button class="doc-nav-toggle" data-action-click="doc-nav-toggle" ' +
            'title="Toggle navigation" aria-label="Toggle navigation">\u2630</button>';
    html += '</div>';

    html += '<div class="doc-nav-modules">';
    for (var i = 0; i < pages.length; i++) {
        var p = pages[i];
        if (p.sortOrder === 0) {
            continue;
        }
        var isCurrent = (p.pageId === current.id);
        var href = doc_prefix + doc_pageFile(p.pageId);
        var label = doc_esc(p.title || p.pageId);
        var icon = doc_esc(p.icon || '\u25C6');
        var activeMod = isCurrent ? ' doc-nav-active' : '';

        html += '<div class="doc-nav-module">';
        html += '<a class="doc-nav-module-link' + activeMod + cc + '" href="' + href + '">';
        html += '<span class="doc-nav-module-icon' + activeMod + cc + '">' + icon + '</span>';
        html += '<span class="doc-nav-module-label' + cc + '">' + label + '</span>';
        if (isCurrent) {
            html += '<span class="doc-nav-module-chev' + cc + '">\u25BC</span>';
        }
        html += '</a>';

        if (isCurrent && currentChildren && currentChildren.length > 0) {
            html += doc_buildRailSubpages(current, currentChildren, href, cc);
        }
        html += '</div>';
    }
    html += '</div>';
    return html;
}

/* Builds the expanded sub-page list shown beneath the active module in the
   rail: the overview link plus each discovered sub-page, with the current view
   marked. */
function doc_buildRailSubpages(current, children, overviewHref, cc) {
    var html = '<div class="doc-nav-subpages' + cc + '">';

    var overviewCurrent = (current.type === 'narrative') ? ' doc-nav-current' : '';
    html += '<a class="doc-nav-subpage' + overviewCurrent + '" href="' + overviewHref + '">';
    html += '<span class="doc-nav-subpage-icon">' + doc_overviewIcon + '</span>';
    html += '<span>Overview</span>';
    html += '</a>';

    for (var k = 0; k < children.length; k++) {
        var child = children[k];
        var isCur = doc_isCurrentChild(current, child);
        var curClass = isCur ? ' doc-nav-current' : '';
        html += '<a class="doc-nav-subpage' + curClass + '" href="' + child.path + '">';
        html += '<span class="doc-nav-subpage-icon">' + doc_esc(child.icon) + '</span>';
        html += '<span>' + doc_esc(child.label) + '</span>';
        html += '</a>';
    }
    html += '</div>';
    return html;
}

/* Builds the fixed-header sub-page link row for the current module: the
   overview pill plus each discovered sub-page, with the current view marked.
   Always visible regardless of rail collapse state. */
function doc_buildHeaderLinks(current, overviewHref, children) {
    var html = '';

    var overviewCurrent = (current.type === 'narrative') ? ' doc-nav-current' : '';
    html += '<a class="doc-subpage-link' + overviewCurrent + '" href="' + overviewHref + '">';
    html += '<span>' + doc_overviewIcon + '</span><span>Overview</span>';
    html += '</a>';

    for (var k = 0; k < children.length; k++) {
        var child = children[k];
        var isCur = doc_isCurrentChild(current, child);
        var curClass = isCur ? ' doc-nav-current' : '';
        html += '<a class="doc-subpage-link' + curClass + '" href="' + child.path + '">';
        html += '<span>' + doc_esc(child.icon) + '</span><span>' + doc_esc(child.label) + '</span>';
        html += '</a>';
    }
    return html;
}

/* Reports whether a discovered sub-page is the page currently being viewed. */
function doc_isCurrentChild(current, child) {
    if (child.slug && current.slug) {
        return (current.type === '-cc' && current.slug === child.slug);
    }
    return (current.type === child.suffix);
}

/* Builds the generated footer markup: any upper footer blocks stacked in order,
   followed by the Contributing anchor that always sits last. To add footer
   content in the future, push a block-builder result onto upperBlocks; the
   Contributing anchor stays pinned at the bottom of every page. */
function doc_buildFooter() {
    var upperBlocks = [];

    return upperBlocks.join('') + doc_buildContributing();
}

/* Builds the Contributing callout that anchors the bottom of every page,
   inviting submissions of new processes to the Applications Team. */
function doc_buildContributing() {
    var mailto = 'mailto:applications@frost-arnett.com' +
        '?subject=xFACts%20New%20Module%20Request' +
        '&body=I%20would%20like%20to%20submit%20a%20possible%20process%20for' +
        '%20consideration%20as%20an%20xFACts%20module.%0A%0AProcess%20Name%3A' +
        '%0ACurrent%20Method%3A%0ABusiness%20Need%3A%0A%0A';
    var html = '<div class="doc-callout doc-tip">';
    html += '<p><strong>Contributing:</strong> This platform is designed to grow ' +
            'organically. If you have a manual process, monitoring need, or utility ' +
            'that could benefit from centralization, contact the ' +
            '<a href="' + mailto + '">Applications Team</a> to discuss adding it as ' +
            'an xFACts module.</p>';
    html += '</div>';
    return html;
}

/* Builds the hub card grid from the module set, skipping the index entry, using
   each module's first-section description as the card blurb, and reusing the
   shared doc-card component. Runs only on the hub page, whose grid is the
   auto-generated module index; authored card grids on other pages are left
   untouched. */
function doc_buildHubCards(pages) {
    if (doc_filename !== 'index.html') {
        return;
    }

    var grid = document.querySelector('.doc-card-grid');
    if (!grid) {
        return;
    }

    var html = '';
    for (var i = 0; i < pages.length; i++) {
        var p = pages[i];
        if (p.sortOrder === 0) {
            continue;
        }

        var narrative = doc_pageFile(p.pageId);
        var desc = '';
        if (p.sections && p.sections.length > 0 && p.sections[0].description) {
            desc = p.sections[0].description;
        }

        html += '<a class="doc-card" href="' + narrative + '">';
        html += '<div class="doc-card-title">' + doc_esc(p.title || p.pageId) + '</div>';
        if (desc) {
            html += '<div class="doc-card-desc">' + doc_esc(desc) + '</div>';
        }
        html += '</a>';
    }
    grid.innerHTML = html;
}

/* Injects the rail markup into the rail mount. */
function doc_injectRail(html) {
    var rail = document.querySelector('.doc-nav');
    if (rail) {
        rail.innerHTML = html;
    }
}

/* Injects the header sub-page link row into the header links mount. */
function doc_injectHeaderLinks(html) {
    var mount = document.querySelector('.doc-subpage-links');
    if (mount) {
        mount.innerHTML = html;
    }
}

/* Injects the generated footer into the footer mount. */
function doc_injectFooter(html) {
    var mount = document.querySelector('.doc-footer');
    if (mount) {
        mount.innerHTML = html;
    }
}

/* Renders the rail, footer, and hub cards from the module set, then triggers
   async sub-page discovery that fills the rail expansion and header link row
   once the existing sub-pages are confirmed. */
function doc_loadAndRender(pages) {
    doc_injectRail(doc_buildRail(pages, null));
    doc_injectFooter(doc_buildFooter());
    doc_buildHubCards(pages);
    doc_discoverChildren(pages);
}

/* ============================================================================
   FUNCTIONS: SUBPAGE DISCOVERY
   ----------------------------------------------------------------------------
   Async discovery of which sub-pages exist for the current module: a HEAD-
   request existence check, and the discovery routine that probes each
   candidate sub-page and, once confirmed, re-renders the rail expansion and
   the header sub-page link row with the confirmed set.
   Prefix: doc
   ============================================================================ */

/* Issues a HEAD request and invokes the callback with whether the URL exists
   (HTTP 200). */
function doc_checkFileExists(url, callback) {
    var xhr = new XMLHttpRequest();
    xhr.open('HEAD', url, true);
    xhr.addEventListener('load', function () {
        callback(xhr.status === 200);
    });
    xhr.addEventListener('error', function () {
        callback(false);
    });
    xhr.send();
}

/* Builds the ordered candidate sub-page list for the current module, using
   registry CC slug data when the module declares named CC guides. */
function doc_buildChecks(currentPage) {
    var ccSlugs = doc_getCcSlugs(currentPage);
    var checks = [];

    if (ccSlugs.length > 0) {
        for (var s = 0; s < ccSlugs.length; s++) {
            checks.push({
                path: doc_prefix + 'cc/' + currentPage.pageId + '-cc-' + ccSlugs[s].slug + '.html',
                suffix: '-cc', folder: 'cc/', label: ccSlugs[s].title,
                icon: doc_childTypes[0].icon, slug: ccSlugs[s].slug, order: s
            });
        }
        for (var j = 1; j < doc_childTypes.length; j++) {
            var ctNamed = doc_childTypes[j];
            checks.push({
                path: doc_prefix + ctNamed.folder + currentPage.pageId + ctNamed.suffix + '.html',
                suffix: ctNamed.suffix, folder: ctNamed.folder, label: ctNamed.label,
                icon: ctNamed.icon, slug: null, order: ccSlugs.length + (j - 1)
            });
        }
    } else {
        for (var n = 0; n < doc_childTypes.length; n++) {
            var ctStd = doc_childTypes[n];
            checks.push({
                path: doc_prefix + ctStd.folder + currentPage.pageId + ctStd.suffix + '.html',
                suffix: ctStd.suffix, folder: ctStd.folder, label: ctStd.label,
                icon: ctStd.icon, slug: null, order: n
            });
        }
    }
    return checks;
}

/* Probes the candidate sub-pages for the current module and, once all probes
   resolve, re-renders the rail expansion and the header link row with the
   confirmed set. */
function doc_discoverChildren(pages) {
    var current = doc_detectCurrent(pages);
    if (!current.id) {
        return;
    }

    var currentPage = null;
    for (var i = 0; i < pages.length; i++) {
        if (pages[i].pageId === current.id) {
            currentPage = pages[i];
            break;
        }
    }
    if (!currentPage || currentPage.sortOrder === 0) {
        return;
    }

    var checks = doc_buildChecks(currentPage);
    var remaining = checks.length;
    var children = [];

    for (var c = 0; c < checks.length; c++) {
        (function (check) {
            doc_checkFileExists(check.path, function (exists) {
                if (exists) {
                    children.push({
                        suffix: check.suffix, folder: check.folder, label: check.label,
                        path: check.path, icon: check.icon, slug: check.slug, order: check.order
                    });
                }
                remaining--;
                if (remaining === 0) {
                    children.sort(function (a, b) { return a.order - b.order; });
                    doc_injectRail(doc_buildRail(pages, children));
                    var overviewHref = doc_prefix + doc_pageFile(currentPage.pageId);
                    doc_injectHeaderLinks(doc_buildHeaderLinks(current, overviewHref, children));
                }
            });
        })(checks[c]);
    }
}

/* ============================================================================
   FUNCTIONS: COLLAPSE STATE
   ----------------------------------------------------------------------------
   The rail collapse state: reading and writing the persisted flag, reporting
   the current state, applying it by toggling the collapsed marker on every
   affected element directly (state-on-element), and binding the toggle action.
   Prefix: doc
   ============================================================================ */

/* Reads the persisted collapse flag from localStorage, defaulting to expanded
   when unset or unavailable. */
function doc_readCollapse() {
    try {
        return window.localStorage.getItem(doc_collapseKey) === '1';
    } catch (e) {
        return false;
    }
}

/* Writes the collapse flag to localStorage, ignoring storage failures. */
function doc_writeCollapse(collapsed) {
    try {
        window.localStorage.setItem(doc_collapseKey, collapsed ? '1' : '0');
    } catch (e) {
        return;
    }
}

/* Reports whether the rail is currently collapsed by reading the rail element,
   falling back to the persisted flag before the rail mounts. */
function doc_isCollapsed() {
    var rail = document.querySelector('.doc-nav');
    if (rail) {
        return rail.classList.contains('doc-nav-collapsed');
    }
    return doc_readCollapse();
}

/* Applies the collapse state by toggling the collapsed marker on the rail and
   on every rail and header element whose appearance depends on it. The selector
   set matches the elements carrying a collapsed compound in docs-base.css. */
function doc_applyCollapse(collapsed) {
    var selectors = [
        '.doc-nav', '.doc-nav-head', '.doc-nav-brand', '.doc-nav-brand-text',
        '.doc-nav-module-link', '.doc-nav-module-icon', '.doc-nav-module-label',
        '.doc-nav-module-chev', '.doc-nav-subpages'
    ];
    for (var i = 0; i < selectors.length; i++) {
        var nodes = document.querySelectorAll(selectors[i]);
        for (var n = 0; n < nodes.length; n++) {
            if (collapsed) {
                nodes[n].classList.add('doc-nav-collapsed');
            } else {
                nodes[n].classList.remove('doc-nav-collapsed');
            }
        }
    }
}

/* Toggles the rail collapse state, persists it, and reapplies it across the
   rail and header elements. */
function doc_toggleCollapse() {
    var collapsed = !doc_isCollapsed();
    doc_writeCollapse(collapsed);
    doc_applyCollapse(collapsed);
}

/* Binds the delegated click listener that runs the collapse toggle when the
   rail toggle button is activated. */
function doc_bindToggle() {
    document.addEventListener('click', function (e) {
        var btn = e.target.closest('.doc-nav-toggle');
        if (btn) {
            doc_toggleCollapse();
        }
    });
}

/* Self-invokes the page boot once the DOM is parsed. */
document.addEventListener('DOMContentLoaded', doc_init);

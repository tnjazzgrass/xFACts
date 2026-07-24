/* ============================================================================
   xFACts Control Center - Documentation Meta Page Renderer (docs-meta.js)
   Location: E:\xFACts-ControlCenter\public\docs\js\docs-meta.js
   Version: Tracked in dbo.System_Metadata (component: Documentation.Site)

   Renders the documentation meta pages from an authored JSON file. Loads the
   payload at page boot, populates the filter controls from the data rather
   than from fixed markup, and builds the sortable grid with its component
   grouping and its per-row expandable detail drawer. Every filter, sort, and
   render helper takes its data and options as arguments so none of them read
   page state directly. All interaction runs through delegated listeners
   registered once at page boot. Consumes doc_esc and doc_fetchJson from
   docs-shared.js.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: DATA SOURCE AND COLUMNS
   STATE: VIEW STATE
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: DATA LOADING
   FUNCTIONS: CONTROL POPULATION
   FUNCTIONS: FILTERING AND SORTING
   FUNCTIONS: GRID RENDERING
   FUNCTIONS: EVENT DELEGATION
   ============================================================================ */

/* ============================================================================
   CONSTANTS: DATA SOURCE AND COLUMNS
   ----------------------------------------------------------------------------
   The render configuration: the served location of the authored data file and
   the grid column set in display order. Each column names the item field it
   reads, the caption its sort control carries, and whether it holds a short
   fixed-vocabulary value that should not absorb the free width.
   Prefix: doc
   ============================================================================ */

/* Root-absolute URL the authored backlog data file is served from. */
const doc_META_DATA_URL = '/docs/data/backlog.json';

/* Grid columns in display order, each naming its item field and caption. */
const doc_metaColumns = [
    { key: 'component', label: 'Component', narrow: true },
    { key: 'priority',  label: 'Priority',  narrow: true },
    { key: 'type',      label: 'Type',      narrow: true },
    { key: 'summary',   label: 'Summary',   narrow: false }
];

/* ============================================================================
   STATE: VIEW STATE
   ----------------------------------------------------------------------------
   The mutable view state built at page boot and mutated by the controls: the
   loaded payload, the active filter values, the field and direction the grid
   is sorted on, and whether rows are grouped under component headers.
   Prefix: doc
   ============================================================================ */

/* Parsed payload as loaded from the data file, null until the load resolves. */
var doc_metaData = null;

/* Active filter values keyed by field; an empty string means unfiltered. */
var doc_metaFilters = {
    component: '',
    priority: '',
    type: '',
    search: ''
};

/* Item field the grid is currently sorted on. */
var doc_metaSortKey = 'priority';

/* Direction of the active sort, either ascending or descending. */
var doc_metaSortDir = 'asc';

/* Whether rows are grouped under component headers. */
var doc_metaGrouped = true;

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The page boot function: confirms the page carries a grid mount, registers
   the delegated interaction listeners, and starts the data load. Async loading
   keeps the fetch off the main thread so it never blocks the initial paint.
   Prefix: doc
   ============================================================================ */

/* Boots the meta page: leaves pages without a grid mount untouched, registers
   the delegated click, change, and input listeners once, then loads and renders
   the data. */
async function doc_init() {
    if (!document.querySelector('.doc-meta-grid')) {
        return;
    }

    document.body.addEventListener('click', doc_metaOnClick);
    document.body.addEventListener('change', doc_metaOnChange);
    document.body.addEventListener('input', doc_metaOnInput);

    await doc_metaLoad();
}

/* ============================================================================
   FUNCTIONS: DATA LOADING
   ----------------------------------------------------------------------------
   The load step: fetches the authored payload, hands it to the control
   population and render passes, and replaces the grid with a plain failure
   notice when the file cannot be read, so a failed load is never a blank page.
   Prefix: doc
   ============================================================================ */

/* Loads the payload and renders the page. On a failed fetch it clears the
   status line and shows the failure notice in place of the grid. */
async function doc_metaLoad() {
    try {
        doc_metaData = await doc_fetchJson(doc_META_DATA_URL);
    } catch (e) {
        doc_metaSetStatus('');
        doc_metaShowMessage('The backlog data could not be loaded. ' + e.message, true);
        return;
    }

    doc_metaFillControls(doc_metaData);
    doc_metaRender();
}

/* Replaces the grid with a single notice, marked as a failure when the error
   flag is set. */
function doc_metaShowMessage(text, isError) {
    var mount = document.querySelector('.doc-meta-grid');
    if (!mount) {
        return;
    }

    var classes = isError ? 'doc-meta-message doc-meta-error' : 'doc-meta-message';
    mount.innerHTML = '<div class="' + classes + '">' + doc_esc(text) + '</div>';
}

/* Writes the supplied text into the status line above the grid. */
function doc_metaSetStatus(text) {
    var status = document.querySelector('.doc-meta-status');
    if (status) {
        status.textContent = text;
    }
}

/* ============================================================================
   FUNCTIONS: CONTROL POPULATION
   ----------------------------------------------------------------------------
   The filter controls are filled from the loaded payload rather than from
   fixed markup: the priority and type vocabularies come from the arrays the
   file declares, while the component list is collected from the items
   themselves so only values actually in use are offered.
   Prefix: doc
   ============================================================================ */

/* Fills every filter dropdown from the payload, taking the declared priority
   and type vocabularies and collecting the component values that the items
   actually carry. */
function doc_metaFillControls(data) {
    doc_metaFillSelect('component', doc_metaDistinct(data.items, 'component'));
    doc_metaFillSelect('priority', data.priorities || []);
    doc_metaFillSelect('type', data.types || []);
}

/* Fills one named dropdown with an unfiltered default followed by the supplied
   values. */
function doc_metaFillSelect(name, values) {
    var select = document.querySelector('.doc-meta-select[data-doc-filter="' + name + '"]');
    if (!select) {
        return;
    }

    var html = '<option value="">All</option>';
    for (var i = 0; i < values.length; i++) {
        html += '<option value="' + doc_esc(values[i]) + '">' + doc_esc(values[i]) + '</option>';
    }
    select.innerHTML = html;
}

/* Collects the distinct non-empty values of one field across the items,
   returned in alphabetical order. */
function doc_metaDistinct(items, key) {
    var values = [];
    for (var i = 0; i < items.length; i++) {
        var value = items[i][key];
        if (value && values.indexOf(value) === -1) {
            values.push(value);
        }
    }
    values.sort();
    return values;
}

/* ============================================================================
   FUNCTIONS: FILTERING AND SORTING
   ----------------------------------------------------------------------------
   The data transforms applied before each render. Each one takes the item set
   and its options as arguments and returns a new set, reading no page state,
   so the grid behaviour can be reused or lifted out without rework. Priority
   sorts by the rank the file declares rather than alphabetically.
   Prefix: doc
   ============================================================================ */

/* Returns the items matching every active filter. */
function doc_metaFilterItems(items, filters) {
    var out = [];
    for (var i = 0; i < items.length; i++) {
        if (doc_metaMatches(items[i], filters)) {
            out.push(items[i]);
        }
    }
    return out;
}

/* Reports whether one item satisfies every active filter, matching the search
   term against the summary, label, and description together. */
function doc_metaMatches(item, filters) {
    if (filters.component && item.component !== filters.component) {
        return false;
    }
    if (filters.priority && item.priority !== filters.priority) {
        return false;
    }
    if (filters.type && item.type !== filters.type) {
        return false;
    }
    if (filters.search) {
        var haystack = ((item.summary || '') + ' ' + (item.label || '') + ' ' + (item.description || '')).toLowerCase();
        if (haystack.indexOf(filters.search.toLowerCase()) === -1) {
            return false;
        }
    }
    return true;
}

/* Returns a sorted copy of the items, ordered on the given field and direction
   with priority ranked by the declared order. */
function doc_metaSortItems(items, sortKey, sortDir, priorities) {
    var sorted = items.slice();
    var factor = (sortDir === 'desc') ? -1 : 1;
    sorted.sort(function (a, b) {
        return doc_metaCompare(a, b, sortKey, priorities) * factor;
    });
    return sorted;
}

/* Compares two items on one field, ranking priority by its position in the
   declared vocabulary and comparing every other field as text. */
function doc_metaCompare(a, b, sortKey, priorities) {
    if (sortKey === 'priority') {
        return priorities.indexOf(a.priority) - priorities.indexOf(b.priority);
    }

    var left = String(a[sortKey] || '').toLowerCase();
    var right = String(b[sortKey] || '').toLowerCase();
    if (left < right) {
        return -1;
    }
    if (left > right) {
        return 1;
    }
    return 0;
}

/* Collects the items into one group per component, ordered alphabetically and
   each preserving the incoming item order. */
function doc_metaGroupByComponent(items) {
    var names = [];
    for (var i = 0; i < items.length; i++) {
        if (names.indexOf(items[i].component) === -1) {
            names.push(items[i].component);
        }
    }
    names.sort();

    var groups = [];
    for (var g = 0; g < names.length; g++) {
        var members = [];
        for (var j = 0; j < items.length; j++) {
            if (items[j].component === names[g]) {
                members.push(items[j]);
            }
        }
        groups.push({ name: names[g], items: members });
    }
    return groups;
}

/* ============================================================================
   FUNCTIONS: GRID RENDERING
   ----------------------------------------------------------------------------
   The markup builders. The render entry point applies the active filters and
   sort then draws either the grouped or the flat body; the builders beneath it
   take their data and column set as arguments and return markup strings, so
   each one is independently reusable. Every value is escaped before insertion.
   Prefix: doc
   ============================================================================ */

/* Renders the grid for the current filters, sort, and grouping, replacing it
   with a notice when nothing matches. */
function doc_metaRender() {
    if (!doc_metaData) {
        return;
    }

    var mount = document.querySelector('.doc-meta-grid');
    if (!mount) {
        return;
    }

    var all = doc_metaData.items || [];
    var priorities = doc_metaData.priorities || [];
    var items = doc_metaFilterItems(all, doc_metaFilters);
    items = doc_metaSortItems(items, doc_metaSortKey, doc_metaSortDir, priorities);
    doc_metaSetStatus('Showing ' + items.length + ' of ' + all.length + ' open items.');

    if (items.length === 0) {
        doc_metaShowMessage('No items match the current filters.', false);
        return;
    }

    var body = doc_metaGrouped
        ? doc_metaGroupedBodyHtml(items, doc_metaColumns, priorities)
        : doc_metaRowsHtml(items, doc_metaColumns, priorities);

    var html = '<table class="doc-meta-table">';
    html += doc_metaHeadHtml(doc_metaColumns, doc_metaSortKey, doc_metaSortDir);
    html += '<tbody>' + body + '</tbody></table>';
    mount.innerHTML = html;
}

/* Builds the header row, marking the active column with its sort direction. */
function doc_metaHeadHtml(columns, sortKey, sortDir) {
    var html = '<thead><tr class="doc-meta-head-row">';
    for (var i = 0; i < columns.length; i++) {
        var column = columns[i];
        var cls = column.narrow ? 'doc-meta-th doc-meta-cell-narrow' : 'doc-meta-th';
        html += '<th class="' + cls + '">';
        html += '<button class="doc-meta-sort" data-doc-sort="' + column.key + '">';
        html += doc_esc(column.label);
        if (sortKey === column.key) {
            var mark = (sortDir === 'desc') ? '&#9660;' : '&#9650;';
            html += '<span class="doc-meta-sort-mark">' + mark + '</span>';
        }
        html += '</button></th>';
    }
    html += '</tr></thead>';
    return html;
}

/* Builds the grouped body: one component header row opening each run of item
   rows that share that component. */
function doc_metaGroupedBodyHtml(items, columns, priorities) {
    var groups = doc_metaGroupByComponent(items);
    var html = '';
    for (var i = 0; i < groups.length; i++) {
        html += '<tr class="doc-meta-group-row">';
        html += '<td class="doc-meta-group-cell" colspan="' + columns.length + '">';
        html += doc_esc(groups[i].name);
        html += '<span class="doc-meta-group-count">' + groups[i].items.length + '</span>';
        html += '</td></tr>';
        html += doc_metaRowsHtml(groups[i].items, columns, priorities);
    }
    return html;
}

/* Builds the item rows for one run of items. */
function doc_metaRowsHtml(items, columns, priorities) {
    var html = '';
    for (var i = 0; i < items.length; i++) {
        html += doc_metaRowHtml(items[i], columns, priorities);
    }
    return html;
}

/* Builds one item row followed by its collapsed detail drawer, with the summary
   cell doubling as the drawer's disclosure control. */
function doc_metaRowHtml(item, columns, priorities) {
    var html = '<tr class="doc-meta-row">';
    html += '<td class="doc-meta-cell doc-meta-cell-narrow">';
    html += '<span class="doc-meta-component">' + doc_esc(item.component) + '</span></td>';
    html += '<td class="doc-meta-cell doc-meta-cell-narrow">';
    html += doc_metaBadgeHtml(item.priority, priorities) + '</td>';
    html += '<td class="doc-meta-cell doc-meta-cell-narrow">';
    html += '<span class="doc-meta-type">' + doc_esc(item.type) + '</span></td>';
    html += '<td class="doc-meta-cell">';
    html += '<button class="doc-meta-toggle">';
    html += '<span class="doc-meta-caret">&#9656;</span>';
    html += '<span class="doc-meta-summary">';
    html += '<span>' + doc_esc(item.summary) + '</span>';
    html += doc_metaLabelHtml(item.label);
    html += '</span>';
    html += '</button></td></tr>';
    html += doc_metaDetailHtml(item, columns.length);
    return html;
}

/* Builds the priority pill, taking its tier styling from the priority's rank in
   the declared vocabulary rather than from its text. */
function doc_metaBadgeHtml(priority, priorities) {
    var rank = priorities.indexOf(priority);
    var tier = 'doc-meta-low';
    if (rank === 0) {
        tier = 'doc-meta-high';
    } else if (rank === 1) {
        tier = 'doc-meta-medium';
    }
    return '<span class="doc-meta-badge ' + tier + '">' + doc_esc(priority) + '</span>';
}

/* Builds the label chip beside the summary, rendering a visible warning in
   place of the handle when the item carries no label. */
function doc_metaLabelHtml(label) {
    if (!label) {
        return '<span class="doc-meta-label doc-meta-label-missing">MISSING LABEL</span>';
    }
    return '<span class="doc-meta-label">' + doc_esc(label) + '</span>';
}

/* Reports whether a detail reference points at a site-served target, which is
   the only case that may render as a link. A reference that is not site-relative
   is a repo path with no served location, so it renders as plain text. */
function doc_metaIsSiteUrl(value) {
    return typeof value === 'string' && value.charAt(0) === '/';
}

/* Builds the collapsed detail drawer holding the full description and, when the
   item carries them, its detail reference and recorded date. */
function doc_metaDetailHtml(item, columnCount) {
    var foot = '';
    if (item.detail_link) {
        foot += '<span><span class="doc-meta-detail-label">Detail</span>';
        if (doc_metaIsSiteUrl(item.detail_link)) {
            foot += '<a class="doc-meta-detail-link" href="' + doc_esc(item.detail_link) + '">';
            foot += doc_esc(item.detail_link) + '</a>';
        } else {
            foot += '<span class="doc-meta-detail-ref">' + doc_esc(item.detail_link) + '</span>';
        }
        foot += '</span>';
    }
    if (item.added) {
        foot += '<span><span class="doc-meta-detail-label">Added</span>';
        foot += doc_esc(item.added) + '</span>';
    }

    var html = '<tr class="doc-meta-detail-row doc-meta-hidden">';
    html += '<td class="doc-meta-detail-cell" colspan="' + columnCount + '">';
    html += '<p class="doc-meta-detail-text">' + doc_esc(item.description) + '</p>';
    if (foot !== '') {
        html += '<div class="doc-meta-detail-foot">' + foot + '</div>';
    }
    html += '</td></tr>';
    return html;
}

/* ============================================================================
   FUNCTIONS: EVENT DELEGATION
   ----------------------------------------------------------------------------
   The delegated handlers registered at page boot. One handler per event type
   inspects the event target and routes it: header controls re-sort the grid,
   a summary control opens or closes its drawer, and the filter controls update
   the view state and redraw.
   Prefix: doc
   ============================================================================ */

/* Routes a click to the sort control or the drawer disclosure control. */
function doc_metaOnClick(event) {
    if (!event.target || !event.target.closest) {
        return;
    }

    var sort = event.target.closest('.doc-meta-sort');
    if (sort) {
        doc_metaApplySort(sort.getAttribute('data-doc-sort'));
        return;
    }

    var toggle = event.target.closest('.doc-meta-toggle');
    if (toggle) {
        doc_metaToggleDetail(toggle);
    }
}

/* Sorts on the given field, reversing the direction when the field is already
   the active one. */
function doc_metaApplySort(key) {
    if (!key) {
        return;
    }

    if (doc_metaSortKey === key) {
        doc_metaSortDir = (doc_metaSortDir === 'asc') ? 'desc' : 'asc';
    } else {
        doc_metaSortKey = key;
        doc_metaSortDir = 'asc';
    }
    doc_metaRender();
}

/* Opens or closes the drawer that follows the control's row, rotating the
   caret to match. */
function doc_metaToggleDetail(toggle) {
    var row = toggle.closest('.doc-meta-row');
    if (!row || !row.nextElementSibling) {
        return;
    }

    row.nextElementSibling.classList.toggle('doc-meta-hidden');
    var caret = toggle.querySelector('.doc-meta-caret');
    if (caret) {
        caret.classList.toggle('doc-meta-open');
    }
}

/* Applies a filter dropdown change or a grouping change, then redraws. */
function doc_metaOnChange(event) {
    var target = event.target;
    if (!target || !target.classList) {
        return;
    }

    if (target.classList.contains('doc-meta-checkbox')) {
        doc_metaGrouped = target.checked;
        doc_metaRender();
        return;
    }

    if (target.classList.contains('doc-meta-select')) {
        doc_metaFilters[target.getAttribute('data-doc-filter')] = target.value;
        doc_metaRender();
    }
}

/* Applies the free-text search as it is typed, then redraws. */
function doc_metaOnInput(event) {
    var target = event.target;
    if (!target || !target.classList) {
        return;
    }

    if (target.classList.contains('doc-meta-search')) {
        doc_metaFilters.search = target.value;
        doc_metaRender();
    }
}

/* Self-invokes the page boot once the DOM is parsed. */
document.addEventListener('DOMContentLoaded', doc_init);

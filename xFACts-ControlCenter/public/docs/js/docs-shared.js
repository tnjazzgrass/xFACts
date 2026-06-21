/* ============================================================================
   xFACts Control Center - Documentation Site Shared Library (docs-shared.js)
   Location: E:\xFACts-ControlCenter\public\docs\js\docs-shared.js
   Version: Tracked in dbo.System_Metadata (component: Documentation.Site)

   Shared function library for the documentation-site zone. Holds utilities
   that more than one docs page or renderer depends on, so each helper lives
   in one place rather than being redefined per file. Loaded ahead of the
   page-level docs scripts that call into it.

   FILE ORGANIZATION
   -----------------
   FUNCTIONS: SHARED UTILITIES
   ============================================================================ */

/* ============================================================================
   FUNCTIONS: SHARED UTILITIES
   ----------------------------------------------------------------------------
   Zone-wide helper functions called by the documentation-site renderers and
   page scripts: HTML-escaping of text destined for innerHTML, and JSON
   resource loading from the docs data directory.
   Prefix: doc
   ============================================================================ */

/* Escapes a value for safe insertion into innerHTML. Returns an empty string
   for null or undefined; otherwise coerces to string and returns the markup-
   safe form with the ampersand, angle brackets, and quote characters encoded. */
function doc_esc(value) {
    if (value === null || value === undefined) {
        return '';
    }
    var div = document.createElement('div');
    div.textContent = String(value);
    return div.innerHTML;
}

/* Fetches a JSON resource and returns the parsed object. Throws when the
   response status is not OK so the caller controls its own error handling
   (inline message, console log, fallback). Does not cache; callers that need
   caching wrap this call. */
async function doc_fetchJson(url) {
    var response = await fetch(url);
    if (!response.ok) {
        throw new Error('HTTP ' + response.status + ' fetching ' + url);
    }
    return response.json();
}

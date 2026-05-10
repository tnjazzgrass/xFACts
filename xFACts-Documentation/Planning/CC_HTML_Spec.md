# Control Center HTML File Format Specification

*These rules are the current authority for HTML markup emitted by Control Center route files. They are settled until explicitly amended; any proposed change is discussed before adoption. Where rationale exists for a rule, it appears in the Appendix at the corresponding section number.*

*Specs describe rules and shapes — never present contents. Statements about how many files currently do something, which pages are empty today, or what the codebase looks like right now do not belong in this document; they age into inaccuracy the moment the codebase changes. If census-style information is needed, it lives in queries against `dbo.Asset_Registry`, not here.*

*The HTML spec governs the shape and content of HTML markup. The PowerShell file containing the markup — its file header, its section banners, its function definitions, its route declarations — is governed by the PowerShell spec. A row in the catalog with `file_type = 'HTML'` represents an HTML construct extracted from a PS file by the HTML populator; the file's PS-level constructs are extracted separately by the PowerShell populator and produce rows with `file_type = 'PS'`.*

---

# Control Center HTML File Format Specification

*These rules are the current authority for HTML markup emitted by Control Center route files. They are settled until explicitly amended; any proposed change is discussed before adoption. Where rationale exists for a rule, it appears in the Appendix at the corresponding section number.*

*Specs describe rules and shapes — never present contents. Statements about how many files currently do something, which pages are empty today, or what the codebase looks like right now do not belong in this document; they age into inaccuracy the moment the codebase changes. If census-style information is needed, it lives in queries against `dbo.Asset_Registry`, not here.*

*The HTML spec governs the shape and content of HTML markup. The PowerShell file containing the markup — its file header, its section banners, its function definitions, its route declarations — is governed by the PowerShell spec. A row in the catalog with `file_type = 'HTML'` represents an HTML construct extracted from a PS file by the HTML populator; the file's PS-level constructs are extracted separately by the PowerShell populator and produce rows with `file_type = 'PS'`.*

---

## 1. Required structure

HTML in the Control Center is emitted from PowerShell route files (`*.ps1` in `scripts/routes/`) and from helper module functions (`*.psm1` in `scripts/modules/`). HTML does not exist as standalone `.html` files. Every HTML construct in the codebase appears inside a PowerShell string token — typically a here-string assigned to a `$html` variable that is then passed to `Write-PodeHtmlResponse`, or a string built up via `System.Text.StringBuilder` inside a helper function.

A page route's HTML must conform to the page-shell structure defined in this section.

### 1.1 Page shell

Every page route emits HTML conforming to this shape, in this exact order:

```
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>
    <link rel="stylesheet" href="/css/<page>.css">
    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="section-<sectionKey>">
$navHtml

    <!-- page header bar -->
    <!-- connection banner placeholder -->
    <!-- page-specific content -->

    <script src="/js/<page>.js"></script>
    <script src="/js/cc-shared.js"></script>
</body>
</html>
```

### 1.2 Page shell rules

- The HTML document opens with `<!DOCTYPE html>` on its own line. The DOCTYPE token is lowercase `<!doctype html>` or uppercase `<!DOCTYPE html>`; mixed-case forms are forbidden. Drift code: `MALFORMED_DOCTYPE`.
- The root element is `<html>` with no attributes. Drift code: `MALFORMED_HTML_ROOT`.
- The `<head>` contains exactly these elements, in this order: one `<title>` element, one or more `<link rel="stylesheet">` elements per Section 3, and nothing else. Drift code: `MALFORMED_HEAD`.
- The `<title>` element's content is the value of the `$browserTitle` PowerShell variable, sourced from `Get-PageBrowserTitle`. Drift code: `FORBIDDEN_HARDCODED_TITLE`.
- The `<body>` element opens with a `class="section-<sectionKey>"` attribute, where `<sectionKey>` matches the page's `RBAC_NavSection.section_key` value. Drift code: `MISSING_BODY_SECTION_CLASS`.
- The first content inside `<body>` is the `$navHtml` substitution, sourced from `Get-NavBarHtml`. Drift code: `MISSING_NAV_SUBSTITUTION`.
- The last content inside `<body>` before `</body>` is the `<script>` tag block per Section 3. Drift code: `MALFORMED_BODY_CLOSE`.

### 1.3 Body content shape

Between `$navHtml` and the `<script>` block, the body contains page content in this implicit order:

1. The page header bar — a single block containing the page title (via `$headerHtml` substitution) and refresh chrome (live indicator, last-updated timestamp, page refresh button, optional engine cards per Section 2).
2. The connection banner placeholder — a single `<div id="connection-banner" class="connection-banner"></div>` element with no content.
3. The page-specific content — any number of layout containers, sections, slideouts, modals, or other page-level constructs.

### 1.4 Body content rules

- The page header bar is the first content element after `$navHtml`. Drift code: `MISSING_HEADER_BAR`.
- The page header bar contains exactly one `$headerHtml` substitution, sourced from `Get-PageHeaderHtml`. Drift code: `FORBIDDEN_HARDCODED_PAGE_HEADER`.
- The connection banner placeholder appears exactly once per page, with `id="connection-banner"` and `class="connection-banner"`. Drift code: `MISSING_CONNECTION_BANNER` if absent.
- The connection banner placeholder is empty — no content between the opening and closing tags. Drift code: `FORBIDDEN_BANNER_CONTENT`.
- Page-specific content begins after the connection banner placeholder.

### 1.5 Helper-emitted HTML fragments

A helper module function that emits an HTML fragment for substitution into a page shell — `Get-NavBarHtml`, `Get-PageHeaderHtml`, `Get-HomePageSections`, and similar — produces partial markup, not a complete page. Helper-emitted fragments are governed by Section 5 (Class attribute conventions), Section 6 (Event handler conventions), and other applicable attribute-level rules, but are not subject to the page-shell rules in §1.1–1.4.

### 1.6 Access-denied page

The 403 Access Denied response — emitted by `Get-AccessDeniedHtml` in `xFACts-Helpers.psm1` — is a complete HTML page that does not conform to the standard page shell defined in §1.1–1.4. It exists to render before authenticated page resources are reachable.

The access-denied page must conform to this rule set:

- The document opens with `<!DOCTYPE html>` per §1.2.
- The document uses an inline `<style>` block in `<head>` containing all visual styling for the page. This is the only HTML construct permitted to use an inline `<style>` block. Drift code: `FORBIDDEN_INLINE_STYLE_BLOCK` is suppressed for `Get-AccessDeniedHtml`.
- The document does not load external CSS or JS files. Drift code `FORBIDDEN_EXTERNAL_ASSET_REFERENCE` does not apply.
- The document does not include `$navHtml`, `$headerHtml`, `$browserTitle` substitutions, or the connection banner placeholder. Drift codes `MISSING_NAV_SUBSTITUTION`, `MISSING_HEADER_BAR`, `MISSING_CONNECTION_BANNER` do not apply.
- All other applicable spec rules apply normally — class attribute conventions (§5), event handler conventions (§6), forbidden inline expressions (§12).

The exemptions listed above apply exclusively to `Get-AccessDeniedHtml`. Any other helper or route file that emits a `<style>` block, omits external asset references, or skips the page-shell substitutions is in violation of the spec.
## 2. Page chrome

The page chrome is the set of structural elements every conforming page renders, regardless of page-specific content. Chrome elements connect the page to the shared `cc-shared.js` runtime, the WebSocket engine-events stream, and the live-update timing system. The exact markup of every chrome element is mandated; deviations are drift.

### 2.1 Page header bar

The page header bar appears as the first content element after `$navHtml`. The header bar contains the page title block on the left and the refresh chrome on the right.

The header bar's outer structure is exactly:

```
<div class="header-bar">
    <div>
        $headerHtml
    </div>
    <div class="header-right">
        <div class="refresh-info">...</div>
        <div class="engine-row">...</div>     ← optional, see §2.3
    </div>
</div>
```

#### 2.1.1 Header bar rules

- The outer container is exactly `<div class="header-bar">`. Drift code: `MALFORMED_HEADER_BAR_CONTAINER`.
- The first child of `header-bar` is exactly `<div>` (no class) containing only the `$headerHtml` substitution. Drift code: `MALFORMED_HEADER_BAR_LEFT`.
- The second child of `header-bar` is exactly `<div class="header-right">`. Drift code: `MALFORMED_HEADER_BAR_RIGHT`.
- `header-right` contains exactly `<div class="refresh-info">` followed optionally by `<div class="engine-row">`. No other children are permitted. Drift code: `MALFORMED_HEADER_RIGHT_CHILDREN`.

### 2.2 Refresh info block

The refresh info block contains the live indicator dot, the live-update status line, the last-update timestamp, and the page refresh button.

The refresh info block's markup is exactly:

```
<div class="refresh-info">
    <span class="live-indicator"></span>
    <span>Live</span> | Updated: <span id="last-update" class="last-updated">-</span>
    <button class="page-refresh-btn" onclick="pageRefresh()" title="Refresh all data">&#8635;</button>
</div>
```

#### 2.2.1 Refresh info rules

- The outer container is exactly `<div class="refresh-info">`. Drift code: `MALFORMED_REFRESH_INFO_CONTAINER`.
- The first child is exactly `<span class="live-indicator"></span>`. The element is empty (no content). Drift code: `MALFORMED_LIVE_INDICATOR`.
- The status line is exactly `<span>Live</span> | Updated: <span id="last-update" class="last-updated">-</span>`. The literal text `| Updated: ` between the two spans is required. The `last-update` span's content is exactly the literal `-`. Drift code: `MALFORMED_LIVE_STATUS_LINE`.
- The page refresh button is exactly `<button class="page-refresh-btn" onclick="pageRefresh()" title="Refresh all data">&#8635;</button>`. Class, onclick, title, and entity reference are mandated verbatim. Drift code: `MALFORMED_REFRESH_BUTTON`.
- The `last-update` ID is the canonical chrome ID for the last-update timestamp. It appears exactly once per page. Drift code: `DUPLICATE_LAST_UPDATE_ID`.

### 2.3 Engine cards

A page that consumes engine events from the orchestrator displays engine cards inside the header bar. Engine cards are optional — pages without orchestrator-driven content omit the entire `engine-row` block. Pages with engine cards must conform exactly to the rules in this section.

The engine row's markup is exactly:

```
<div class="engine-row">
    <div class="engine-card" id="card-engine-<slug>">
        <span class="engine-label">LABEL</span>
        <div class="engine-bar disabled" id="engine-bar-<slug>"></div>
        <span class="engine-countdown" id="engine-cd-<slug>">&nbsp;</span>
    </div>
    <div class="engine-card" id="card-engine-<slug>">
        ...
    </div>
    ...
</div>
```

#### 2.3.1 Engine row rules

- The outer container is exactly `<div class="engine-row">`. Drift code: `MALFORMED_ENGINE_ROW_CONTAINER`.
- The engine row contains one or more `engine-card` children, in declaration order matching `Orchestrator.ProcessRegistry.cc_sort_order` for the page's process set. Drift code: `ENGINE_CARD_ORDER_MISMATCH`.
- The engine row contains no other children. Drift code: `MALFORMED_ENGINE_ROW_CHILDREN`.

#### 2.3.2 Engine card rules

- Each engine card's structure is exactly the four-element block shown above: card div, label span, bar div, countdown span. Drift code: `MALFORMED_ENGINE_CARD`.
- The card div has exactly the classes `engine-card` (no others) and the ID `card-engine-<slug>`. Drift code: `MALFORMED_ENGINE_CARD_ATTRIBUTES`.
- The label span has exactly the class `engine-label` and contains the engine label text from `Orchestrator.ProcessRegistry.cc_engine_label`. Drift code: `MALFORMED_ENGINE_LABEL`.
- The bar div has exactly the classes `engine-bar disabled` and the ID `engine-bar-<slug>`. The element is empty (no content). Drift code: `MALFORMED_ENGINE_BAR`.
- The countdown span has exactly the class `engine-countdown` and the ID `engine-cd-<slug>`. The element's content is exactly the entity reference `&nbsp;`. Drift code: `MALFORMED_ENGINE_COUNTDOWN`.

#### 2.3.3 Engine slug registry sourcing

The `<slug>` value used in the three IDs (`card-engine-<slug>`, `engine-bar-<slug>`, `engine-cd-<slug>`) is sourced from `Orchestrator.ProcessRegistry.cc_engine_slug` for the orchestrator process the card represents.

The four cc-prefixed columns on ProcessRegistry govern engine card display:

| Column | Purpose |
|---|---|
| `cc_engine_slug` | The slug used in card IDs (e.g., `nb`, `pmt`, `collect`). |
| `cc_engine_label` | The text shown in the `engine-label` span (e.g., `NB`, `PMT`, `Collect`). |
| `cc_page_route` | The page route on which this process appears as an engine card. |
| `cc_sort_order` | The display order of the card within the page's engine row. |

The `run_mode` column on ProcessRegistry determines whether the four cc-prefixed columns must be populated:

- `run_mode = 1` (active scheduled process) → all four cc-prefixed columns must be populated. Drift code: `MISSING_ENGINE_CARD_REGISTRATION` if any are NULL.
- `run_mode = 2` (active on-demand process / queue processor) → all four cc-prefixed columns must be NULL. Queue processors do not appear as engine cards. Drift code: `UNEXPECTED_ENGINE_CARD_REGISTRATION` if any are populated.
- `run_mode = 0` (inactive) → either acceptable; inactive processes are not validated.

#### 2.3.4 Slug validation rules

The HTML populator validates the slug used in engine card IDs against `Orchestrator.ProcessRegistry.cc_engine_slug` for the process the card represents.

- The `<slug>` value in `card-engine-<slug>`, `engine-bar-<slug>`, and `engine-cd-<slug>` must match the `cc_engine_slug` registered for the corresponding process. Drift code: `ENGINE_SLUG_REGISTRY_MISMATCH`.
- The label text inside the `engine-label` span must match the `cc_engine_label` registered for the corresponding process. Drift code: `ENGINE_LABEL_REGISTRY_MISMATCH`.
- The page emitting the engine card must match the process's `cc_page_route`. Drift code: `ENGINE_CARD_PAGE_MISMATCH`.

Additional validations of the JS-side `ENGINE_PROCESSES` declaration against the registry are governed by the JavaScript spec, not this spec. Those drift codes are emitted by the JS populator on rows with `file_type = 'JS'`.

### 2.4 Connection banner placeholder

The connection banner placeholder is governed by §1.4 (an empty `<div>` with `id="connection-banner"` and `class="connection-banner"`, appearing exactly once per page). The banner's content is rendered at runtime by `cc-shared.js` based on WebSocket connection state. The placeholder element exists only as a DOM target for the runtime.
## 3. Asset references

A page references external CSS and JavaScript files via `<link rel="stylesheet">` and `<script src="">` elements. Asset references identify the file path to load, the load order, and the placement within the page shell.

### 3.1 CSS file references

CSS file references appear inside `<head>` between the `<title>` element and the closing `</head>` tag. A page references exactly two CSS files, in this exact order:

```
<link rel="stylesheet" href="/css/<page>.css">
<link rel="stylesheet" href="/css/cc-shared.css">
```

#### 3.1.1 CSS reference rules

- Every CSS reference uses the form `<link rel="stylesheet" href="...">` exactly. No additional attributes are permitted (no `type=`, no `media=`, no `crossorigin=`). Drift code: `MALFORMED_CSS_LINK`.
- The first CSS reference is the page-specific stylesheet. Its `href` value is `/css/<page>.css` where `<page>` matches the page's URL slug. Drift code: `MALFORMED_PAGE_CSS_REFERENCE`.
- The second CSS reference is exactly `<link rel="stylesheet" href="/css/cc-shared.css">`. Drift code: `MALFORMED_SHARED_CSS_REFERENCE`.
- The page-specific reference appears before the shared reference. Drift code: `CSS_REFERENCE_ORDER_VIOLATION`.
- Exactly two CSS references appear in `<head>`. Pages do not load other CSS files. Drift code: `UNEXPECTED_CSS_REFERENCE`.

### 3.2 JavaScript file references

JavaScript file references appear immediately before the closing `</body>` tag. A page references exactly two JavaScript files, in this exact order:

```
<script src="/js/<page>.js"></script>
<script src="/js/cc-shared.js"></script>
```

#### 3.2.1 JS reference rules

- Every JS reference uses the form `<script src="..."></script>` exactly. The element is empty (no content between opening and closing tags). No additional attributes are permitted (no `type=`, no `defer`, no `async`, no `crossorigin=`). Drift code: `MALFORMED_JS_SCRIPT`.
- The first JS reference is the page-specific script. Its `src` value is `/js/<page>.js` where `<page>` matches the page's URL slug. Drift code: `MALFORMED_PAGE_JS_REFERENCE`.
- The second JS reference is exactly `<script src="/js/cc-shared.js"></script>`. Drift code: `MALFORMED_SHARED_JS_REFERENCE`.
- The page-specific reference appears before the shared reference. Drift code: `JS_REFERENCE_ORDER_VIOLATION`.
- Exactly two JS references appear in `<body>`. Pages do not load other JS files via `<script>` tags. Drift code: `UNEXPECTED_JS_REFERENCE`.
- The JS reference block is the last content inside `<body>`. No other elements appear between the JS references and the closing `</body>` tag. Drift code: `JS_REFERENCE_NOT_LAST`.

### 3.3 Asset path mapping

The `<page>` placeholder in CSS and JS reference paths matches the page's URL slug:

| Page route | CSS path | JS path |
|---|---|---|
| `/batch-monitoring` | `/css/batch-monitoring.css` | `/js/batch-monitoring.js` |
| `/departmental/business-services` | `/css/business-services.css` | `/js/business-services.js` |
| `/server-health` | `/css/server-health.css` | `/js/server-health.js` |

The slug is derived from the rightmost path segment of the page route, lowercase, hyphen-separated.

The HTML populator resolves each asset reference against `CSS_FILE` and `JS_FILE` definition rows already in the catalog. References that resolve to a known file have `source_file` populated with the matching definition's file path. References that do not resolve (the target file does not exist or has not been cataloged yet) have `source_file = '<undefined>'`. This mirrors the `CSS_CLASS USAGE` resolution pattern.

### 3.4 Inline asset blocks

The HTML spec forbids inline `<style>` blocks and inline `<script>` blocks containing code (script blocks with `src=` only are permitted per §3.2). These are enumerated in Section 12 (Forbidden patterns). The exception for `Get-AccessDeniedHtml` is governed by §1.6.

### 3.5 Asset references in helper-emitted HTML

Helper module functions that emit HTML fragments (e.g., `Get-NavBarHtml`, `Get-PageHeaderHtml`) do not declare asset references. Their output is consumed by route files via `$variable` substitution and inherits the asset references declared by the consuming page. Helper-emitted HTML fragments containing `<link>` or `<script>` elements are drift. Drift code: `FORBIDDEN_HELPER_ASSET_REFERENCE`.
## 4. ID conventions

Element IDs are unique identifiers assigned via the `id="..."` attribute. IDs serve as DOM lookup targets for JavaScript (`getElementById`), CSS hooks for chrome elements, and ARIA reference anchors. Every ID on a page falls into one of two categories: chrome IDs (mandated platform-wide identifiers) or page-local IDs (page-author-defined identifiers scoped to a single page).

### 4.1 Chrome IDs

Chrome IDs are platform-wide identifiers used by `cc-shared.js`, `cc-shared.css`, and the WebSocket runtime to locate specific DOM elements. The set of chrome IDs is closed; pages do not invent new chrome IDs. Adding a new chrome ID to the platform requires a spec amendment to add it to the table below.

| Chrome ID | Purpose | Defined in |
|---|---|---|
| `last-update` | Timestamp display target. Updated by `cc-shared.js` on each successful refresh. | §2.2 |
| `connection-banner` | Connection state banner placeholder. Populated by `cc-shared.js` on WebSocket state change. | §1.4, §2.4 |
| `card-engine-<slug>` | Engine card outer container. Slug from `Orchestrator.ProcessRegistry.cc_engine_slug`. | §2.3 |
| `engine-bar-<slug>` | Engine status bar element. Updated by WebSocket events. | §2.3 |
| `engine-cd-<slug>` | Engine countdown text element. Updated by JS-side timer logic. | §2.3 |

#### 4.1.1 Chrome ID rules

- A page must declare each chrome ID exactly when its associated chrome element is present. Chrome ID declaration is governed by the rules in the section that defines the element (§1.4 for connection banner, §2.2 for last-update, §2.3 for engine card IDs).
- Chrome IDs are never used as page-local IDs. A page-local element may not be assigned `id="last-update"` or any other chrome ID. Drift code: `CHROME_ID_REUSED_AS_LOCAL`.
- Chrome IDs are never used in CSS selectors. The CSS spec forbids ID selectors entirely (§13 of CSS spec, drift code `FORBIDDEN_ID_SELECTOR`); chrome IDs exist solely for JS DOM lookups. This is enforced by the CSS spec.

### 4.2 Page-local IDs

Page-local IDs are page-author-defined identifiers used as DOM lookup targets for page-specific JavaScript and as anchor points for slideouts, modals, and form controls. Page-local IDs must be prefixed with the page's `cc_prefix` from `Component_Registry`.

#### 4.2.1 Page-local ID format

A page-local ID has the form `<prefix>-<purpose>` where:

- `<prefix>` is the page's three-character prefix from `Component_Registry.cc_prefix` (e.g., `bsv`, `bkp`, `bch`).
- `<purpose>` is a descriptive identifier, lowercase, hyphen-separated, indicating what the element is or what it contains (e.g., `pipeline-card-host`, `slideout-title`, `detail-modal-body`).

Example: `bsv-history-tree`, `bkp-storage-drive-c`, `bch-batch-slideout-overlay`.

#### 4.2.2 Page-local ID rules

- Every page-local ID begins with the page's registered `cc_prefix` followed by a hyphen. Drift code: `MISSING_PREFIX_ID`.
- An ID that begins with a known prefix from another page's registration emits drift indicating cross-page prefix collision. Drift code: `CROSS_PAGE_PREFIX_COLLISION`.
- Page-local IDs are unique within the page. The same ID value declared more than once on a page emits drift on every duplicate. Drift code: `DUPLICATE_ID_DECLARATION`.
- Page-local IDs use lowercase letters, digits, and hyphens only. Other characters (underscores, periods, mixed case) emit drift. Drift code: `MALFORMED_ID_VALUE`.

#### 4.2.3 JavaScript references to page-local IDs

JavaScript code that references page-local IDs (e.g., `document.getElementById('bsv-modal-detail')`) must use the same prefixed form as the HTML declaration. The HTML populator emits `HTML_ID DEFINITION` rows for IDs declared in markup; the JS populator (running after HTML in the populator pipeline) emits `HTML_ID USAGE` rows for IDs referenced in JS. The two row types resolve against each other via `component_name` at JS-populator scan time.

A JS reference to an ID with no matching HTML declaration resolves with `source_file = '<undefined>'`. The HTML populator does not emit drift on the JS side; cross-spec validation of ID-string formatting in JS code is the JavaScript spec's responsibility. The HTML populator's role is to produce the authoritative `HTML_ID DEFINITION` rows that the JS populator resolves against.

### 4.3 Slideout, modal, and panel IDs

Slideouts, modals, and slide-up panels are common page constructs that anchor multiple related elements via IDs. The spec mandates a convention for these ID groupings to keep cross-page comparison meaningful.

#### 4.3.1 Slideout ID convention

A slideout consists of an overlay element and a panel element. The IDs for both follow this form:

- Overlay: `<prefix>-slideout-<purpose>-overlay`
- Panel: `<prefix>-slideout-<purpose>`

Example: a request-detail slideout on the BusinessServices page would use `bsv-slideout-request-overlay` (overlay) and `bsv-slideout-request` (panel).

#### 4.3.2 Modal ID convention

A modal consists of an overlay element and a dialog element:

- Overlay: `<prefix>-modal-<purpose>-overlay`
- Dialog: `<prefix>-modal-<purpose>`

#### 4.3.3 Slide-up panel ID convention

A slide-up panel consists of a backdrop element and a panel element:

- Backdrop: `<prefix>-slideup-<purpose>-backdrop`
- Panel: `<prefix>-slideup-<purpose>`

#### 4.3.4 Slideout, modal, and panel rules

- A slideout's overlay and panel IDs both use the `<prefix>-slideout-<purpose>-*` form. Drift code: `MALFORMED_SLIDEOUT_ID`.
- A modal's overlay and dialog IDs both use the `<prefix>-modal-<purpose>-*` form. Drift code: `MALFORMED_MODAL_ID`.
- A slide-up panel's backdrop and panel IDs both use the `<prefix>-slideup-<purpose>-*` form. Drift code: `MALFORMED_SLIDEUP_ID`.
- A page that declares one half of a pair (overlay only, or panel only) without the other emits drift. Drift code: `INCOMPLETE_OVERLAY_PAIR`.

#### 4.3.5 Purpose comments

Every slideout, modal, and slide-up panel declaration must be preceded by an HTML comment describing the purpose of the construct. The comment immediately precedes the overlay (or backdrop) element and applies to both elements of the pair.

```
<!-- Slideout for displaying request details with comments and timeline -->
<div id="bsv-slideout-request-overlay" class="slide-panel-overlay" onclick="..."></div>
<div id="bsv-slideout-request" class="slide-panel xwide">...</div>
```

The comment text is read by the HTML populator into the `purpose_description` column for both rows of the pair (overlay and panel).

Drift code: `MISSING_PANEL_PURPOSE_COMMENT` if a slideout, modal, or slide-up panel declaration is not preceded by an HTML comment.

### 4.4 Form field IDs

Form input elements (`<input>`, `<select>`, `<textarea>`) used as page-local form fields follow the page-local ID format defined in §4.2. The spec does not mandate a specific naming convention beyond the prefix-and-hyphen rule (e.g., `bsv-date-range-start` is permitted; `bsv-input-modal-field` is permitted).

### 4.5 IDs in helper-emitted HTML

Helper module functions that emit HTML fragments (e.g., `Get-NavBarHtml`, `Get-PageHeaderHtml`) may declare IDs that are platform-shared rather than page-local. These IDs follow the same chrome-ID rules in §4.1: they are part of the platform's chrome contract and are not subject to page-prefix rules.

A helper function emitting HTML with a page-prefixed ID is drift, since helpers do not belong to a specific page. Drift code: `FORBIDDEN_HELPER_PAGE_PREFIX_ID`.
## 5. Class attribute conventions

The `class` attribute on HTML elements references CSS classes that style the element. Class references in HTML are catalog `CSS_CLASS USAGE` rows; they resolve against `CSS_CLASS DEFINITION` rows emitted by the CSS populator.

Class attribute values fall into two categories: static values (the class names are literal strings in the markup) and dynamic values (the class names are computed from PowerShell variables). Each category has its own rules.

### 5.1 Static class values

A static class value is a literal string with no PowerShell variable interpolation. Each space-separated token in the value is one class name and produces one `CSS_CLASS USAGE` row.

```
<div class="bsv-pipeline-card">                       ← one class
<div class="bsv-pipeline-card warning">               ← two classes
<div class="bsv-pipeline-card warning highlighted">   ← three classes
```

#### 5.1.1 Static class rules

- A class attribute value contains zero or more class names separated by single spaces. Multiple consecutive spaces, leading or trailing whitespace, and tabs within the value emit drift. Drift code: `MALFORMED_CLASS_VALUE_WHITESPACE`.
- Each class name in the value uses lowercase letters, digits, and hyphens only. Other characters (uppercase, underscores, periods) emit drift on the row for that class. Drift code: `MALFORMED_CLASS_NAME`.
- Each class name is unique within the value. Duplicate class names in the same attribute (e.g., `class="card card"`) emit drift. Drift code: `DUPLICATE_CLASS_IN_VALUE`.
- A class name that does not begin with the page's `cc_prefix` and is not defined in `cc-shared.css` emits drift. Drift code: `CLASS_PREFIX_MISMATCH`. Shared classes (defined in `cc-shared.css`) are scope-resolved at populator runtime and exempt from prefix matching; page-local classes must match the page's prefix.

### 5.2 Dynamic class values

A dynamic class value is one where part or all of the attribute value is computed from a PowerShell variable. This pattern is required when class composition depends on runtime state — active/inactive flags, status indicators, conditional modifiers.

The spec mandates exactly one pattern for dynamic class assembly. All other forms of dynamic class composition are forbidden.

#### 5.2.1 The mandated pattern

A dynamic class value is built by:

1. Initializing a PowerShell array variable with the base class as its first element.
2. Conditionally appending modifier classes to the array.
3. Joining the array with a single space.
4. Substituting the joined string into the attribute via PowerShell variable interpolation.

```powershell
$classList = @('nav-link')
if ($isActive) { $classList += 'active' }
if ($accentClass) { $classList += $accentClass }
$cssClasses = ($classList -join ' ')

# In the HTML emission:
[void]$sb.AppendLine("<a class=`"$cssClasses`">$label</a>")
```

The resulting `class` attribute value contains exactly one substitution token (`$cssClasses`) and no other content. The classes it expands to are determined entirely by the array contents.

#### 5.2.2 Dynamic class rules

- A class attribute containing PowerShell variable interpolation must use the array-join pattern. The attribute value is exactly `class="$<variable>"` with the variable holding the joined string.
- The array variable's first element is the base class — the class that always appears regardless of state. Subsequent elements are conditional modifiers. The array literal must be the first construct in the assembly sequence.
- The array elements that are literal strings produce `CSS_CLASS USAGE` rows in the catalog. Conditionally-appended dynamic values (variables holding strings determined at runtime, such as parameters passed into the function) are not catalogable individually; their presence is recorded via the `has_dynamic_content` flag on the static rows from the same attribute (see §5.5).

#### 5.2.3 Forbidden dynamic patterns

| Pattern | Drift code |
|---|---|
| `class="nav-link$accent"` (interpolation appended to static text) | `INLINE_CLASS_CONCATENATION` |
| `class="$type wide"` or `class="card $modifier"` (interpolation followed or preceded by static text) | `INLINE_CLASS_PREFIX_MIX` |
| `class="$a $b"` (multiple top-level interpolations, neither using array-join) | `INLINE_CLASS_MULTI_INTERPOLATION` |
| `class="${a}wide"` or `class="$($section.accent)wide"` (PowerShell `${...}` or `$(...)` form mixed with static text) | `INLINE_CLASS_BRACED_INTERPOLATION` |

The mandated array-join pattern (§5.2.1) is the only legitimate way to construct a dynamic class string. Each forbidden form has its own drift code so resolution is precise and queryable.

### 5.3 Class catalog rows

Each class name in HTML markup produces one `CSS_CLASS USAGE` row.

| Column | Value |
|---|---|
| `component_type` | `CSS_CLASS` |
| `component_name` | The class name (e.g., `bsv-pipeline-card`, `nav-link`) |
| `reference_type` | `USAGE` |
| `signature` | The full `class="..."` attribute value, including all class names in the attribute |
| `scope` | Resolved from CSS_CLASS DEFINITION rows: `SHARED` if defined in `cc-shared.css`, `LOCAL` if defined in a page-specific CSS file |
| `source_file` | The file containing the matching DEFINITION row, or `'<undefined>'` if no match |
| `parent_function` | The PS function emitting the markup (when applicable) |
| `parent_object` | NULL initially; populated by PS populator with the route path |
| `has_dynamic_content` | TRUE when the class attribute also contains runtime-only class composition not statically catalogable; FALSE when the attribute is fully resolved |

The `signature` column carries the full attribute value (not just the individual class name), which makes class-combination queries possible — "find every place where `bsv-pipeline-card` appears with `warning`" is a single signature pattern match.

### 5.4 Class references in helper-emitted HTML

Helper module functions that emit HTML fragments produce class references the same way route files do. Helper-emitted classes resolve against the same CSS DEFINITION rows. There is no special handling for helpers — class rules apply uniformly.

When a helper uses dynamic class assembly (the array-join pattern), the array literal and conditional appends within the helper function's body are visible to the populator. Variables passed into the helper as parameters (e.g., `$accentClass` from a caller) are not statically resolvable; their presence is recorded via `has_dynamic_content` on the helper's static class rows (see §5.5).

### 5.5 Static fragments and the dynamic content flag

The populator emits `CSS_CLASS USAGE` rows for every class name it can statically resolve in a class attribute value. When the attribute also contains runtime-only class composition (parameter-passed classes, classes built from data the populator cannot read), the populator does not invent rows for the unresolvable portions. Instead, it sets `has_dynamic_content = TRUE` on the static rows from the same attribute.

For example:

```powershell
function Get-NavLinkHtml {
    param([string]$AccentClass, [bool]$IsActive)

    $classList = @('nav-link')
    if ($IsActive) { $classList += 'active' }
    if ($AccentClass) { $classList += $AccentClass }
    $cssClasses = ($classList -join ' ')

    return "<a class=`"$cssClasses`">Link</a>"
}
```

The populator emits:

- `CSS_CLASS USAGE` for `nav-link` with `has_dynamic_content = TRUE` (literal in array initialization, but a parameter-passed class is also being conditionally added)
- `CSS_CLASS USAGE` for `active` with `has_dynamic_content = TRUE` (literal in conditional append, same reason)

If `$AccentClass` is replaced with another literal string (e.g., a hardcoded `'departmental'`), the populator emits a third row for `departmental` and updates all three rows to `has_dynamic_content = FALSE` (no remaining unresolvable composition).

The `has_dynamic_content` flag lets queries distinguish between:

- Class compositions the catalog has fully captured (`has_dynamic_content = FALSE`)
- Class compositions where additional runtime classes may also be applied (`has_dynamic_content = TRUE`)

This flag also applies to JS-side class extraction (Group A rows from JS template literals). It is not meaningful for CSS rows, which are always fully literal.

### 5.6 Class catalog and CSS resolution

The HTML populator resolves each emitted `CSS_CLASS USAGE` row's `scope` and `source_file` columns against `CSS_CLASS DEFINITION` rows already in the catalog at populator scan time. Per the populator pipeline order (CSS → HTML → JS → PS), CSS DEFINITION rows always exist before HTML scans, except in standalone-reload scenarios.

When standalone-reloading the HTML populator before CSS has been populated, every USAGE row emitted will resolve to `scope = LOCAL` and `source_file = '<undefined>'`. The populator emits a startup warning when no CSS DEFINITION rows are present and continues without resolution.
## 6. Event handler conventions

Inline event handlers are HTML attributes whose name begins with `on` (`onclick`, `onchange`, `onkeydown`, `onsubmit`, etc.) and whose value is a JavaScript expression executed when the named event fires. Event handlers are the connection point between HTML markup and page-specific JavaScript.

The spec mandates that inline event handlers contain only function calls, not arbitrary JavaScript expressions. Each event handler attribute produces a `JS_FUNCTION USAGE` row in the catalog.

### 6.1 Allowed event handler format

An event handler attribute value contains exactly one function call. The function must be either a chrome function (defined in `cc-shared.js`) or a page-local function (defined in the page's `.js` file).

```
onclick="pageRefresh()"                              ← chrome function call
onclick="closeSlideout()"                            ← chrome function call
onclick="bsv_openRequestDetail(123)"                 ← page-local function call
onchange="bsv_setActiveFilter(this.value)"           ← page-local function call with argument
```

#### 6.1.1 Event handler rules

- The attribute value contains exactly one function call. Drift code: `MULTIPLE_HANDLER_STATEMENTS` if more than one statement appears (e.g., `onclick="doA(); doB()"`).
- The function call is a top-level expression. The value cannot include conditional logic, variable assignments, property access expressions, or any other JavaScript syntax. Drift code: `INLINE_HANDLER_EXPRESSION`.
- The function name is followed immediately by an opening parenthesis. Whitespace between name and parenthesis emits drift. Drift code: `MALFORMED_HANDLER_CALL`.
- The function call's closing parenthesis is the last non-whitespace character in the attribute value. Trailing semicolons emit drift. Drift code: `TRAILING_HANDLER_SEMICOLON`.

### 6.2 Function naming

The function called by an event handler must follow the JavaScript spec's naming conventions for the appropriate scope. The HTML spec mandates that handlers reference functions by name only — no namespace traversal, no method invocation on objects.

#### 6.2.1 Page-local function calls

Page-local functions are defined in the page's JavaScript file and follow the JavaScript spec's prefix convention: `<prefix>_<funcName>` where `<prefix>` matches the page's `cc_prefix` (e.g., `bsv_openRequestDetail`, `bch_filterBatches`).

#### 6.2.2 Chrome function calls

Chrome functions are defined in `cc-shared.js` and have no prefix (e.g., `pageRefresh`, `closeSlideout`, `showAlert`, `showConfirm`). The set of chrome functions is governed by the JavaScript spec.

#### 6.2.3 Function naming rules

- A handler's function name uses underscore-separated lowercase or camelCase per the JavaScript spec. The HTML spec does not redefine these rules; it cross-references them.
- A handler that calls a function via dotted property access (e.g., `onclick="Admin.openX()"`) emits drift. The CC platform does not use revealing-module patterns. Drift code: `FORBIDDEN_REVEALING_MODULE_CALL`.
- A handler that calls a method on a built-in object (e.g., `onclick="window.location.href='/admin'"`) emits drift. Navigation must use `<a href="...">` (see §7); other built-in object access must be wrapped in a named page-local function. Drift code: `FORBIDDEN_BUILTIN_METHOD_CALL`.
- A handler whose function name is not registered as a chrome function and does not match the page's prefix emits drift. Drift code: `HANDLER_FUNCTION_NAME_MISMATCH`.

### 6.3 Forbidden inline patterns

Some inline patterns appear plausible but are forbidden because they bypass JavaScript spec validation. The catalog cannot resolve them as `JS_FUNCTION USAGE` rows.

| Pattern | Drift code |
|---|---|
| `onclick="event.stopPropagation()"` (calling a method on the event object) | `FORBIDDEN_EVENT_METHOD_CALL` |
| `onkeydown="if(event.key==='Enter') doX()"` (conditional logic in handler) | `FORBIDDEN_HANDLER_CONDITIONAL` |
| `onclick="this.classList.toggle('active')"` (DOM manipulation in handler) | `FORBIDDEN_INLINE_DOM_OPERATION` |
| `onclick="window.location.href='/admin'"` (assignment expression) | `FORBIDDEN_INLINE_ASSIGNMENT` |
| `onclick="javascript:doX()"` (javascript: pseudo-protocol) | `FORBIDDEN_JAVASCRIPT_PROTOCOL` |

Each of these patterns must be rewritten as a named function call. The function definition lives in the page's `.js` file or in `cc-shared.js`.

For example, the conditional `onkeydown="if(event.key==='Enter') confirmInput()"` becomes:

```html
<input type="text" onkeydown="bsv_confirmInputOnEnter(event)">
```

```javascript
function bsv_confirmInputOnEnter(event) {
    if (event.key === 'Enter') {
        bsv_confirmInput();
    }
}
```

The function takes the event object as an argument when needed and encapsulates the conditional logic.

### 6.4 Argument conventions

An event handler may pass arguments to the called function. The spec mandates conventions for what arguments are permitted.

#### 6.4.1 Allowed argument forms

```
onclick="bsv_openRequestDetail(123)"                 ← literal argument
onclick="bsv_openRequestDetail('user-input')"        ← string literal argument
onchange="bsv_setActiveFilter(this.value)"           ← element value reference
onclick="bsv_handleAction(this)"                     ← element reference
onclick="bsv_processRow(this, 'priority')"           ← multiple arguments
```

#### 6.4.2 Argument rules

- Arguments are literal values (numbers, strings), `this` (a reference to the element firing the event), or `this.<property>` (a property of the element). No other expressions are permitted as arguments. Drift code: `FORBIDDEN_ARGUMENT_EXPRESSION`.
- String literal arguments use single quotes (`'value'`) since the surrounding attribute value uses double quotes. Drift code: `MALFORMED_ARGUMENT_QUOTING`.
- Multiple arguments are separated by `, ` (comma followed by single space). Drift code: `MALFORMED_ARGUMENT_LIST`.

### 6.5 Catalog rows for event handlers

Each event handler attribute produces one `JS_FUNCTION USAGE` row.

| Column | Value |
|---|---|
| `component_type` | `JS_FUNCTION` |
| `component_name` | The function name (e.g., `pageRefresh`, `bsv_openRequestDetail`) |
| `reference_type` | `USAGE` |
| `signature` | The full event handler attribute (e.g., `onclick="bsv_openRequestDetail(123)"`) |
| `scope` | Resolved from `JS_FUNCTION DEFINITION` rows: `SHARED` if defined in `cc-shared.js`, `LOCAL` if defined in a page-specific JS file |
| `source_file` | The file containing the matching DEFINITION row, or `'<undefined>'` if no match |

The HTML populator does not validate that the function exists; it emits the USAGE row and lets the JS populator's DEFINITION rows resolve via `component_name` lookup. A handler calling a function that doesn't exist anywhere in the cataloged JS produces `source_file = '<undefined>'` — a queryable indicator of missing implementation.

### 6.6 Event handlers in helper-emitted HTML

Helper module functions that emit HTML fragments may include event handler attributes. These follow the same rules as route-file event handlers — function calls only, no inline expressions, naming per §6.2.

Helper-emitted event handlers must reference chrome functions only (functions defined in `cc-shared.js`). A helper emitting an event handler that calls a page-prefixed function (e.g., `Get-NavBarHtml` emitting `onclick="bsv_navHandler()"`) couples the helper to a specific page, defeating the purpose of having a helper. Drift code: `FORBIDDEN_HELPER_PAGE_FUNCTION_CALL`.
## 7. data-* attribute conventions

The `data-*` attribute family is HTML's standard mechanism for attaching custom data to elements. Values are read by JavaScript at runtime via `element.dataset.<name>` (or `element.getAttribute('data-<name>')`). In Control Center pages, `data-*` attributes carry filter values, view state, sort modes, and similar JS-readable parameters that don't belong in `class` or `id`.

### 7.1 data-* attribute format

A `data-*` attribute name follows the form `data-<name>` where `<name>` uses lowercase letters, digits, and hyphens only. The HTML standard mandates this lowercase-and-hyphen form; the spec restates it for completeness.

```
<button data-filter="ALL">                           ← filter selector
<button data-window="30">                            ← timeline window in minutes
<div data-batch-id="12345">                          ← entity reference
<button data-action="kill-spid" data-spid="42">      ← action with parameter
```

### 7.2 data-* attribute rules

- Attribute names use lowercase letters, digits, and hyphens only after the `data-` prefix. Drift code: `MALFORMED_DATA_ATTRIBUTE_NAME`. (Uppercase is forbidden by the HTML standard; the spec rejects it as well.)
- Attribute values are static strings. PowerShell variable interpolation in `data-*` values is forbidden except via the same rules as class attributes — values must come from a fully-resolved variable, not mixed inline. Drift code: `FORBIDDEN_INLINE_DATA_INTERPOLATION` for any attribute value containing both static text and `$` interpolation.
- A page-author may use any `data-*` attribute name. There is no closed set; the catalog tracks every distinct name.
- `data-*` values are treated as opaque strings by the spec. The spec does not validate value content (e.g., does not require `data-spid` values be integer-shaped).

### 7.3 Catalog rows for data-* attributes

Each `data-*` attribute on each element produces one `HTML_DATA_ATTRIBUTE DEFINITION` row.

| Column | Value |
|---|---|
| `component_type` | `HTML_DATA_ATTRIBUTE` |
| `component_name` | The attribute name including the `data-` prefix (e.g., `data-filter`, `data-batch-id`) |
| `reference_type` | `DEFINITION` |
| `signature` | The full attribute (e.g., `data-filter="ALL"`) |
| `scope` | `LOCAL` for page-author-defined attributes; `SHARED` for chrome-related attributes (currently none) |
| `source_file` | The file containing the row (route file or helper) |
| `parent_function` | The PS function emitting the markup (when applicable) |
| `has_dynamic_content` | TRUE when value composition involves runtime data; FALSE when fully static |

The `signature` carries the full attribute including the value, which makes value-comparison queries possible — "find every page where `data-filter='ALL'` appears" is a single signature pattern match.

### 7.4 data-* attributes referenced from JavaScript

JavaScript code that reads `data-*` attributes (via `element.dataset.batchId` or `element.getAttribute('data-batch-id')`) produces `HTML_DATA_ATTRIBUTE USAGE` rows in the JS populator. These rows resolve against the HTML populator's DEFINITION rows via `component_name`, mirroring the same pattern as ID and class resolution.

Cross-population validation rules for `data-*` references in JavaScript are governed by the JavaScript spec.

### 7.5 data-* attributes in helper-emitted HTML

Helper module functions that emit HTML fragments may declare `data-*` attributes following the same rules as route files. Helper-emitted `data-*` attributes are catalogued with `scope = SHARED` since they apply to every page consuming the helper.

A helper emitting a `data-*` attribute that's only meaningful on one specific page (e.g., a page-specific filter value) couples the helper to that page. Drift code: `FORBIDDEN_HELPER_PAGE_DATA_ATTRIBUTE`.
## 8. Text content and entity references

Text content is human-readable copy that appears in HTML markup — section titles, button labels, status messages, tooltip text, placeholder text. HTML entity references and direct Unicode characters are graphical glyphs (icons, special symbols) used as decorative or semantic content.

The catalog records text and entities for two reasons: structural completeness (every visible element is accounted for) and cross-page consistency comparison (similar UI elements should display similar copy across pages).

### 8.1 What counts as text content

Text content is any non-trivial character data that appears between HTML element opening and closing tags, plus user-facing attribute values that carry display text.

#### 8.1.1 Element text content

Character data appearing between an element's opening and closing tags is text content when it is not whitespace-only.

```
<h2>Live Activity</h2>                              ← "Live Activity" is text
<p>Loading data...</p>                              ← "Loading data..." is text
<button>Cancel</button>                             ← "Cancel" is text
<div>                                                ← whitespace-only, ignored
    <span>Hello</span>                              ← "Hello" is text
</div>
```

#### 8.1.2 User-facing attribute values

Four HTML attributes carry user-facing display text and are catalogued as text content:

| Attribute | Purpose |
|---|---|
| `title` | Tooltip text shown on hover |
| `placeholder` | Ghost text shown in empty form fields |
| `aria-label` | Screen-reader accessibility label |
| `alt` | Alternative text for images |

These are governed by §8.2 and §8.3 along with element text.

#### 8.1.3 What is not text content

The following are not catalogued as text content:

- Pure whitespace between elements (newlines, spaces used for indentation)
- Text inside `<script>` and `<style>` blocks (these are forbidden in route HTML by §12 anyway)
- HTML comment content (catalogued separately by §10)
- Element attribute values other than the four listed in §8.1.2

### 8.2 Text content rules

The catalog records text content as it appears, without normalization. Display copy variation across pages is the primary signal the catalog surfaces — different copy on similar elements is information, not noise.

- Text content character data is stored verbatim in the catalog row's `component_name` and `raw_text` columns. Whitespace within the text (interior spaces) is preserved. Leading and trailing whitespace is trimmed before storage.
- A text content row's `signature` indicates the source of the text (see §8.4).
- Text content containing PowerShell variable interpolation (e.g., `<h1>$pageTitle</h1>` or `title="Refresh $itemType"`) is catalogued with `has_dynamic_content = TRUE` on the row. The static portions are stored in `component_name`; the row signals the value will differ at runtime.
- The spec does not validate text content against any standard. Cross-page consistency emerges from catalog query analysis, not from spec mandates.

#### 8.2.1 Storage and length

Text content is stored in two columns:

- `component_name` — a categorical name derived from the element context (see §8.2.2). Always fits within the column's 256-character maximum.
- `raw_text` — the literal text content as it appears in the source, with no transformation other than trimming leading and trailing whitespace.

The categorical name is the queryable handle for cross-page comparison. The literal text in `raw_text` is the answer to "what does this page actually say?" Together they let queries scope by element kind (`component_name`) and inspect content (`raw_text`).

#### 8.2.2 Categorical name derivation

The HTML populator constructs `component_name` for each `HTML_TEXT` row by inspecting the parent element and applying these rules:

| Source | component_name |
|---|---|
| Text inside an element with one or more classes | `<tag>-<first-class-token-with-page-prefix-stripped>` |
| Text inside an element with no class | `<tag>-text` |
| Value of a user-facing attribute (`title`, `placeholder`, `aria-label`, `alt`) | `attr-<attribute-name>` |

The page prefix is recognized by lookup against `Component_Registry.cc_prefix` for the page that contains the row. When a class begins with the page's prefix followed by a hyphen, the prefix and hyphen are removed before the leading class token is taken. When a class does not begin with the page's prefix (e.g., it is a shared class from `cc-shared.css`), the leading class token is taken as-is.

Examples:

| Source markup | component_name |
|---|---|
| `<h2 class="bsv-section-title">Live Activity</h2>` | `h2-section-title` |
| `<h2 class="section-title">Live Activity</h2>` (shared class) | `h2-section-title` |
| `<h2>No Title Class</h2>` | `h2-text` |
| `<button class="page-refresh-btn" title="Refresh all data">↻</button>` (text node `↻`) | `button-page-refresh-btn` |
| `<span class="bsv-engine-label">NB</span>` | `span-engine-label` |
| `<input placeholder="Search...">` (no text node, but the placeholder value is text) | `attr-placeholder` |
| `<button title="Refresh all data">↻</button>` (the title attribute value) | `attr-title` |

The categorical naming rule means cross-page comparison is direct:

- "All section titles platform-wide" → `WHERE component_name = 'h2-section-title'`
- "All loading messages" → `WHERE component_name LIKE '%-loading%'` (loose, since loading divs vary by tag)
- "All tooltip text" → `WHERE component_name = 'attr-title'`
- "All engine labels" → `WHERE component_name = 'span-engine-label'`

#### 8.2.2 Text inside helper-emitted HTML

Text content emitted by helper functions (e.g., the "Sorry, you don't have permission..." text in `Get-AccessDeniedHtml`) is catalogued the same way as route-emitted text, with `scope = SHARED`. This makes shared text content (which appears identically on every page) queryable as a distinct group.

### 8.3 Entity references and direct Unicode

HTML entity references (`&amp;`, `&times;`, `&#9881;`, etc.) and direct Unicode characters appearing as element text content or text-content attribute values are catalogued as a separate component type from regular text. They are typically used as icons, special symbols, or decorative glyphs.

#### 8.3.1 Forms catalogued

Three forms are catalogued as `HTML_ENTITY` rows:

| Form | Example | signature value |
|---|---|---|
| Named entity reference | `&times;`, `&nbsp;`, `&amp;` | `entity_named` |
| Numeric entity reference | `&#9881;`, `&#x2699;` | `entity_numeric` |
| Direct Unicode character | `⚙`, `⚡`, `→` (typed inline in the source) | `direct_unicode` |

A common ASCII string like "Hello World" is not catalogued as `HTML_ENTITY` — only special characters that serve as glyphs or symbols, which are characters above the basic ASCII printable range or named-entity escapes.

#### 8.3.2 Entity catalog rows

Each entity reference or direct Unicode character produces one `HTML_ENTITY DEFINITION` row.

| Column | Value |
|---|---|
| `component_type` | `HTML_ENTITY` |
| `component_name` | The literal entity reference or Unicode character (e.g., `&#9881;`, `⚙`) |
| `reference_type` | `DEFINITION` |
| `signature` | One of `entity_named`, `entity_numeric`, `direct_unicode` |
| `scope` | `LOCAL` for page-emitted entities; `SHARED` for helper-emitted entities |
| `source_file` | The file containing the row |
| `parent_function` | The PS function emitting the markup (when applicable) |

#### 8.3.3 Entity rules

The spec does not mandate which form (named entity, numeric entity, or direct Unicode) authors should use. The catalog tracks every distinct form used. Cross-form consistency is a Phase 3 candidate for tightening if catalog analysis surfaces inconsistency worth eliminating.

### 8.4 Signature column for text content

Under the categorical naming model (§8.2.2), `component_name` already carries the source distinction (`attr-title` vs `h2-section-title` vs `button-page-refresh-btn`). The `signature` column on `HTML_TEXT` rows is therefore unused for these rows; it is set to NULL.

This is a deliberate departure from the convention used for other row types (where `signature` distinguishes shape variants). For `HTML_TEXT`, the categorical `component_name` does that work directly.

### 8.5 Catalog rows for text content

Each text content node and each user-facing attribute value produces one `HTML_TEXT DEFINITION` row.

| Column | Value |
|---|---|
| `component_type` | `HTML_TEXT` |
| `component_name` | The categorical name derived per §8.2.2 (e.g., `h2-section-title`, `attr-title`) |
| `reference_type` | `DEFINITION` |
| `signature` | NULL (the categorical `component_name` already conveys source) |
| `scope` | `LOCAL` or `SHARED` based on whether the row originates in a route or helper |
| `source_file` | The file containing the row |
| `parent_function` | The PS function emitting the markup (when applicable) |
| `raw_text` | The literal text content as it appears in the source |
| `has_dynamic_content` | TRUE when the text contains PowerShell variable interpolation; FALSE when fully static |

### 8.6 Text content drift codes

The spec mandates few rules on text content because the catalog's purpose for text is primarily descriptive (surface what exists) rather than prescriptive (mandate what should be).

| Drift code | Trigger |
|---|---|
| `MALFORMED_TEXT_INTERPOLATION` | Text contains PowerShell variable interpolation that uses forbidden patterns from §5.2.3 (inline mixing, etc.) — the same patterns forbidden in class attributes |
| `EMPTY_DISPLAY_TEXT` | A user-facing attribute (`title`, `placeholder`, `aria-label`, `alt`) is declared with an empty value (e.g., `title=""`). User-facing attributes exist to display text; a declared-but-empty value is treated as an authoring error. |

These are the only text-content-specific drift codes. Cross-page consistency analysis happens via queries against the catalog, not via drift codes — the catalog model is the surfacing mechanism.
## 9. Inline SVG

Inline SVG is `<svg>...</svg>` markup embedded directly in HTML. SVG is used for icons, decorative graphics, and small diagrams that benefit from being part of the document rather than loaded as separate image files.

The HTML spec catalogs SVG at the outer-element level only — one row per `<svg>` element regardless of internal complexity. The internal structure of the SVG (paths, polygons, gradients, etc.) is stored in `raw_text` for reference but is not parsed into individual catalog rows.

### 9.1 What gets catalogued

Each `<svg>` element in HTML markup produces one `HTML_SVG DEFINITION` row.

```
<svg width="20" height="20" viewBox="0 0 20 20" fill="currentColor">
    <path d="M10 0c5.5 0 10 4.5 10 10..."/>
</svg>
```

The above produces one row. The `<path>` element inside is not catalogued separately.

### 9.2 SVG catalog rows

| Column | Value |
|---|---|
| `component_type` | `HTML_SVG` |
| `component_name` | A categorical name derived per §9.3 |
| `reference_type` | `DEFINITION` |
| `signature` | NULL (the categorical `component_name` already conveys source) |
| `scope` | `LOCAL` for page-emitted SVG; `SHARED` for helper-emitted SVG |
| `source_file` | The file containing the row |
| `parent_function` | The PS function emitting the markup (when applicable) |
| `raw_text` | The complete `<svg>...</svg>` markup, including all child elements and attributes |

### 9.3 SVG categorical naming

`component_name` for an SVG row follows the same derivation pattern as text content (§8.2.2), based on the SVG's class attribute:

| Source | component_name |
|---|---|
| `<svg class="bsv-icon-warning">...` | `svg-icon-warning` |
| `<svg class="icon-success">...` (shared class) | `svg-icon-success` |
| `<svg>...` (no class) | `svg-untagged` |

The page prefix is stripped from the leading class token by the same lookup as §8.2.2.

### 9.4 SVG content rules

- The `<svg>` element's outer attributes (`width`, `height`, `viewBox`, `fill`, etc.) are part of `raw_text` and not separately validated.
- The internal SVG structure is not validated by the spec. Whatever appears between `<svg>` and `</svg>` is stored verbatim.
- An SVG element that contains PowerShell variable interpolation in its outer attributes or internal markup emits `has_dynamic_content = TRUE`. The interpolation pattern itself is not enforced.

### 9.5 SVG and the inline-style discussion

`<svg>` elements may legitimately contain `<style>` blocks for SVG-internal styling. These are SVG-scoped, not HTML-scoped, and do not violate the §12 prohibition on inline `<style>` blocks in HTML. The spec recognizes this as an SVG-internal concern outside HTML spec validation.

### 9.6 SVG drift codes

The HTML spec mandates few rules on SVG content because SVG is treated as opaque markup at the catalog level.

| Drift code | Trigger |
|---|---|
| `MALFORMED_SVG_INTERPOLATION` | An SVG's outer markup contains PowerShell variable interpolation that uses forbidden patterns from §5.2.3 (inline mixing, etc.) |

This is the only SVG-specific drift code. Cross-page SVG consistency comparison happens via queries against `raw_text`.
## 10. Comments

HTML comments (`<!-- ... -->`) appear in route files as section dividers, structural annotations, and the purpose comments mandated for slideouts/modals/panels by §4.3.5. The HTML spec recognizes a small set of legitimate comment uses and catalogs them all.

### 10.1 Recognized comment kinds

Three kinds of HTML comments are recognized by the spec:

| Kind | Format | Purpose |
|---|---|---|
| Section divider | Multi-line block of `<!-- ===== -->` style | Visual separation between major content blocks within a route file's HTML |
| Inline annotation | Single-line `<!-- short text -->` | Brief contextual note on a specific element or block |
| Panel purpose comment | Single-line `<!-- short text -->` immediately preceding a slideout, modal, or slide-up panel | Required by §4.3.5; describes the construct's purpose |

### 10.2 Section dividers

A section divider is a multi-line block comment that visually separates major content blocks within an HTML emission. The format is:

```
<!-- ============================================================================
     SECTION TITLE
     ============================================================================ -->
```

Section dividers are useful when the HTML inside a single route handler grows large enough that visual separation aids readability. They are not required.

#### 10.2.1 Section divider rules

- The opening and closing rule lines are exactly 76 `=` characters (matching the CSS spec's banner convention).
- The title line is uppercase letters, digits, spaces, and select punctuation (commas, colons, hyphens). The title is human-readable.
- The block opens with `<!--` and closes with `-->`.
- A section divider may appear anywhere within the HTML body content — between the page header bar and content sections, between distinct content sections, or wherever visual separation aids reading.

### 10.3 Inline annotations

An inline annotation is a single-line comment providing brief context on the next element or block:

```
<!-- Toolbar across the top of the timeline -->
<div class="timeline-toolbar">
    ...
</div>
```

Inline annotations are optional and are not subject to a fixed format beyond standard HTML comment syntax.

### 10.4 Panel purpose comments

Panel purpose comments are required by §4.3.5 for slideouts, modals, and slide-up panels. They are inline annotations placed immediately before the overlay (or backdrop) element of the construct:

```
<!-- Slideout for displaying request details with comments and timeline -->
<div id="bsv-slideout-request-overlay" class="slide-panel-overlay" onclick="..."></div>
<div id="bsv-slideout-request" class="slide-panel xwide">...</div>
```

The HTML populator reads the comment text into the `purpose_description` column for both rows of the construct (overlay and panel). See §4.3.5 for the full rule.

### 10.5 Catalog rows for comments

Each recognized comment produces one `HTML_COMMENT DEFINITION` row in the catalog.

| Column | Value |
|---|---|
| `component_type` | `HTML_COMMENT` |
| `component_name` | The categorical name based on comment kind: `comment-section-divider`, `comment-inline`, `comment-panel-purpose` |
| `reference_type` | `DEFINITION` |
| `signature` | NULL |
| `scope` | `LOCAL` for page-emitted comments; `SHARED` for helper-emitted comments |
| `source_file` | The file containing the row |
| `parent_function` | The PS function emitting the markup (when applicable) |
| `raw_text` | The complete comment text including delimiters |

#### 10.5.1 Categorical name derivation

The HTML populator distinguishes between the three comment kinds based on shape and position:

| Categorical name | Trigger |
|---|---|
| `comment-section-divider` | Multi-line block comment whose body contains rule lines (76-character `=` runs) per §10.2 |
| `comment-panel-purpose` | Single-line comment immediately preceding a slideout overlay (`<prefix>-slideout-<purpose>-overlay`), modal overlay (`<prefix>-modal-<purpose>-overlay`), or slide-up backdrop (`<prefix>-slideup-<purpose>-backdrop`) per §4.3 |
| `comment-inline` | Any other single-line comment |

When a comment is categorized as `comment-panel-purpose`, its text is also written into the `purpose_description` column for both rows of the slideout/modal/panel construct it precedes (per §4.3.5). For `comment-inline` and `comment-section-divider` rows, `purpose_description` is not derived from the comment text.

A comment whose text resembles a panel purpose comment but is not positioned immediately before a slideout/modal/panel construct is categorized as `comment-inline`. The populator's categorization is determined by structural context, not by comment content.

### 10.6 Forbidden comment patterns

| Pattern | Drift code |
|---|---|
| Comment containing `--` within the body (other than the closing `-->`) | `MALFORMED_COMMENT_DASHES` |
| Comment containing PowerShell variable interpolation | `FORBIDDEN_COMMENT_INTERPOLATION` |
| Comment that is unclosed (opening `<!--` without matching `-->`) | `MALFORMED_COMMENT_UNCLOSED` |

The first rule reflects the HTML standard: `--` inside a comment body produces undefined parsing behavior in some browsers.

### 10.7 Comments inside other constructs

Comments inside `<script>` blocks (`//` or `/* */` style) are JavaScript comments, not HTML comments. They are governed by the JavaScript spec, not this section.

Comments inside `<svg>` blocks are SVG-internal and are catalogued as part of the SVG's `raw_text` (§9.4), not as separate `HTML_COMMENT` rows.

PowerShell-side comments (`#` and `<# ... #>`) inside the PS file containing the HTML are governed by the PowerShell spec, not this section. They are not part of HTML markup.
## 11. Required patterns summary

Every conforming HTML emission must satisfy these requirements. This section is a summary index; the authoritative rule for each item lives in the section cited.

### 11.1 Page shell

1. Open with `<!DOCTYPE html>` (§1.2)
2. Root element `<html>` with no attributes (§1.2)
3. `<head>` contains exactly one `<title>$browserTitle</title>` and the mandated `<link>` tags, nothing else (§1.2, §3.1)
4. `<body class="section-<sectionKey>">` opens body content (§1.2)
5. First content inside `<body>` is `$navHtml` substitution (§1.2)
6. Last content inside `<body>` is the JS reference block (§1.2, §3.2)

### 11.2 Page chrome

1. Page header bar appears as first content after `$navHtml` (§1.4, §2.1)
2. Header bar contains `$headerHtml` substitution and refresh-info block in mandated structure (§2.1, §2.2)
3. Refresh info block contains live indicator, status line, last-update span, and refresh button in exact mandated markup (§2.2)
4. Connection banner placeholder appears once per page as empty `<div>` (§1.4)
5. Engine cards (when present) follow exact structure and registry-sourced slugs/labels (§2.3)

### 11.3 Asset references

1. Exactly two CSS files referenced in `<head>`: page-specific then `cc-shared.css` (§3.1)
2. Exactly two JS files referenced before `</body>`: page-specific then `cc-shared.js` (§3.2)
3. JS reference block is the last content in `<body>` (§3.2)
4. No `defer`, `async`, or other attributes on `<script>` tags (§3.2)

### 11.4 ID conventions

1. Chrome IDs come from the closed set in §4.1; new chrome IDs require spec amendment
2. Page-local IDs use `<prefix>-<purpose>` form where prefix matches `Component_Registry.cc_prefix` (§4.2)
3. Slideout IDs use `<prefix>-slideout-<purpose>-overlay` and `<prefix>-slideout-<purpose>` (§4.3.1)
4. Modal IDs use `<prefix>-modal-<purpose>-overlay` and `<prefix>-modal-<purpose>` (§4.3.2)
5. Slide-up panel IDs use `<prefix>-slideup-<purpose>-backdrop` and `<prefix>-slideup-<purpose>` (§4.3.3)
6. Every slideout, modal, and slide-up panel is preceded by an HTML purpose comment (§4.3.5)
7. JS references to page-local IDs use the same prefixed form as HTML declarations (§4.2.3)

### 11.5 Class attributes

1. Static class values use space-separated lowercase tokens (§5.1)
2. Page-local classes match the page's `cc_prefix`; shared classes are recognized via cross-population lookup (§5.1.1)
3. Dynamic class assembly uses the array-join pattern only (§5.2.1)
4. `class` attribute values containing PowerShell interpolation use a single fully-resolved variable (§5.2.2)

### 11.6 Event handlers

1. Each event handler attribute contains exactly one function call (§6.1.1)
2. Function names are chrome (cc-shared.js) or page-prefixed `<prefix>_<funcName>` (§6.2)
3. Argument values are literals, `this`, or `this.<property>` (§6.4)
4. String literal arguments use single quotes inside the double-quoted attribute (§6.4.2)
5. Helpers may emit chrome function calls only — no page-prefixed function calls (§6.6)

### 11.7 data-* attributes

1. Names use lowercase letters, digits, and hyphens after the `data-` prefix (§7.2)
2. Values are static strings or fully-resolved variables; no inline interpolation mixing (§7.2)
3. Helpers emit only platform-shared `data-*` attributes; page-specific data-* in helpers is forbidden (§7.5)

### 11.8 Text content and entities

1. Text content character data and the four user-facing attributes (`title`, `placeholder`, `aria-label`, `alt`) are catalogued (§8.1)
2. Categorical naming derives `component_name` from element context (§8.2.2)
3. Entity references and direct Unicode are catalogued in three forms (named, numeric, direct) (§8.3)
4. User-facing attributes are not declared with empty values (§8.6)

### 11.9 SVG

1. Inline `<svg>` elements are catalogued at the outer-element level only; internals stored in `raw_text` (§9.1)
2. Categorical naming follows the same rule as text content (§9.3)
3. SVG-internal `<style>` blocks are SVG-scoped and exempt from the §12 inline-style prohibition (§9.5)

### 11.10 Comments

1. Recognized comment kinds: section divider, inline annotation, panel purpose comment (§10.1)
2. Section dividers use 76-character `=` rule lines (§10.2.1)
3. Panel purpose comments precede slideouts, modals, and slide-up panels per §4.3.5 (§10.4)
4. Comment categorization is determined by structural context, not comment content (§10.5.1)

### 11.11 Helper-emitted HTML

1. Helpers do not declare asset references (§3.5)
2. Helpers emit only chrome IDs, never page-prefixed IDs (§4.5)
3. Helpers emit only chrome function call event handlers, never page-prefixed function calls (§6.6)
4. Helpers emit only platform-shared `data-*` attributes (§7.5)

---
## 12. Forbidden patterns

This section consolidates patterns that are forbidden by spec rules in §1–§10. Each row maps a pattern to its drift code and the rule that forbids it. Section 15 carries the full drift code reference with descriptions.

### 12.1 Page shell forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| DOCTYPE missing or mixed-case | `MALFORMED_DOCTYPE` | §1.2 |
| `<html>` element with attributes | `MALFORMED_HTML_ROOT` | §1.2 |
| `<head>` containing elements other than `<title>` and `<link>` | `MALFORMED_HEAD` | §1.2 |
| `<title>` content hardcoded instead of `$browserTitle` substitution | `FORBIDDEN_HARDCODED_TITLE` | §1.2 |
| `<body>` missing `class="section-<sectionKey>"` | `MISSING_BODY_SECTION_CLASS` | §1.2 |
| First content inside `<body>` is not `$navHtml` | `MISSING_NAV_SUBSTITUTION` | §1.2 |
| Content appears between JS reference block and `</body>` | `MALFORMED_BODY_CLOSE`, `JS_REFERENCE_NOT_LAST` | §1.2, §3.2 |
| Page header bar missing | `MISSING_HEADER_BAR` | §1.4 |
| Page header hardcoded instead of `$headerHtml` substitution | `FORBIDDEN_HARDCODED_PAGE_HEADER` | §1.4 |
| Connection banner placeholder missing | `MISSING_CONNECTION_BANNER` | §1.4 |
| Connection banner placeholder contains content | `FORBIDDEN_BANNER_CONTENT` | §1.4 |

### 12.2 Page chrome forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| Header bar outer container malformed | `MALFORMED_HEADER_BAR_CONTAINER` | §2.1 |
| Header bar children malformed | `MALFORMED_HEADER_BAR_LEFT`, `MALFORMED_HEADER_BAR_RIGHT`, `MALFORMED_HEADER_RIGHT_CHILDREN` | §2.1 |
| Refresh info block malformed | `MALFORMED_REFRESH_INFO_CONTAINER` | §2.2 |
| Live indicator span malformed | `MALFORMED_LIVE_INDICATOR` | §2.2 |
| Live status line malformed | `MALFORMED_LIVE_STATUS_LINE` | §2.2 |
| Page refresh button markup deviates from mandated form | `MALFORMED_REFRESH_BUTTON` | §2.2 |
| `last-update` ID declared more than once | `DUPLICATE_LAST_UPDATE_ID` | §2.2 |
| Engine row container malformed | `MALFORMED_ENGINE_ROW_CONTAINER`, `MALFORMED_ENGINE_ROW_CHILDREN` | §2.3 |
| Engine card structure deviates from mandated form | `MALFORMED_ENGINE_CARD`, `MALFORMED_ENGINE_CARD_ATTRIBUTES`, `MALFORMED_ENGINE_LABEL`, `MALFORMED_ENGINE_BAR`, `MALFORMED_ENGINE_COUNTDOWN` | §2.3 |
| Engine card order doesn't match `cc_sort_order` | `ENGINE_CARD_ORDER_MISMATCH` | §2.3 |
| Active scheduled process missing engine card registration | `MISSING_ENGINE_CARD_REGISTRATION` | §2.3 |
| Queue processor process has engine card registration | `UNEXPECTED_ENGINE_CARD_REGISTRATION` | §2.3 |
| Slug in card IDs doesn't match `cc_engine_slug` | `ENGINE_SLUG_REGISTRY_MISMATCH` | §2.3 |
| Label text doesn't match `cc_engine_label` | `ENGINE_LABEL_REGISTRY_MISMATCH` | §2.3 |
| Engine card on a page that doesn't match `cc_page_route` | `ENGINE_CARD_PAGE_MISMATCH` | §2.3 |

### 12.3 Asset reference forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| Malformed `<link>` tag | `MALFORMED_CSS_LINK` | §3.1 |
| Page-specific CSS reference malformed | `MALFORMED_PAGE_CSS_REFERENCE` | §3.1 |
| Shared CSS reference malformed | `MALFORMED_SHARED_CSS_REFERENCE` | §3.1 |
| CSS references in wrong order | `CSS_REFERENCE_ORDER_VIOLATION` | §3.1 |
| Unexpected number of CSS references | `UNEXPECTED_CSS_REFERENCE` | §3.1 |
| Malformed `<script>` tag | `MALFORMED_JS_SCRIPT` | §3.2 |
| Page-specific JS reference malformed | `MALFORMED_PAGE_JS_REFERENCE` | §3.2 |
| Shared JS reference malformed | `MALFORMED_SHARED_JS_REFERENCE` | §3.2 |
| JS references in wrong order | `JS_REFERENCE_ORDER_VIOLATION` | §3.2 |
| Unexpected number of JS references | `UNEXPECTED_JS_REFERENCE` | §3.2 |
| Helper emits `<link>` or `<script>` reference | `FORBIDDEN_HELPER_ASSET_REFERENCE` | §3.5 |

### 12.4 ID forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| Chrome ID reused as page-local ID | `CHROME_ID_REUSED_AS_LOCAL` | §4.1 |
| Page-local ID missing prefix | `MISSING_PREFIX_ID` | §4.2 |
| Page-local ID uses another page's prefix | `CROSS_PAGE_PREFIX_COLLISION` | §4.2 |
| Same ID declared twice on a page | `DUPLICATE_ID_DECLARATION` | §4.2 |
| ID value contains forbidden characters | `MALFORMED_ID_VALUE` | §4.2 |
| Slideout/modal/panel ID malformed | `MALFORMED_SLIDEOUT_ID`, `MALFORMED_MODAL_ID`, `MALFORMED_SLIDEUP_ID` | §4.3 |
| Slideout/modal/panel pair incomplete | `INCOMPLETE_OVERLAY_PAIR` | §4.3 |
| Slideout/modal/panel missing purpose comment | `MISSING_PANEL_PURPOSE_COMMENT` | §4.3.5 |
| Helper emits page-prefixed ID | `FORBIDDEN_HELPER_PAGE_PREFIX_ID` | §4.5 |

### 12.5 Class attribute forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| Class value contains malformed whitespace | `MALFORMED_CLASS_VALUE_WHITESPACE` | §5.1 |
| Class name contains forbidden characters | `MALFORMED_CLASS_NAME` | §5.1 |
| Duplicate class in same attribute | `DUPLICATE_CLASS_IN_VALUE` | §5.1 |
| Class doesn't match page prefix or shared definitions | `CLASS_PREFIX_MISMATCH` | §5.1 |
| `class="nav-link$accent"` (interpolation appended to static text) | `INLINE_CLASS_CONCATENATION` | §5.2.3 |
| `class="$type wide"` (interpolation followed/preceded by static text) | `INLINE_CLASS_PREFIX_MIX` | §5.2.3 |
| `class="$a $b"` (multiple interpolations, neither using array-join) | `INLINE_CLASS_MULTI_INTERPOLATION` | §5.2.3 |
| `class="${a}wide"` or `class="$($x)wide"` | `INLINE_CLASS_BRACED_INTERPOLATION` | §5.2.3 |

### 12.6 Event handler forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| Multiple statements in handler | `MULTIPLE_HANDLER_STATEMENTS` | §6.1 |
| Inline expression instead of function call | `INLINE_HANDLER_EXPRESSION` | §6.1 |
| Whitespace between function name and paren | `MALFORMED_HANDLER_CALL` | §6.1 |
| Trailing semicolon in handler | `TRAILING_HANDLER_SEMICOLON` | §6.1 |
| Revealing-module call (`Module.func()`) | `FORBIDDEN_REVEALING_MODULE_CALL` | §6.2 |
| Built-in method call (e.g., `window.location.href = ...`) | `FORBIDDEN_BUILTIN_METHOD_CALL` | §6.2 |
| Function name doesn't match prefix or chrome conventions | `HANDLER_FUNCTION_NAME_MISMATCH` | §6.2 |
| `event.method()` call inline | `FORBIDDEN_EVENT_METHOD_CALL` | §6.3 |
| Conditional in handler | `FORBIDDEN_HANDLER_CONDITIONAL` | §6.3 |
| Inline DOM operation | `FORBIDDEN_INLINE_DOM_OPERATION` | §6.3 |
| Inline assignment expression | `FORBIDDEN_INLINE_ASSIGNMENT` | §6.3 |
| `javascript:` pseudo-protocol | `FORBIDDEN_JAVASCRIPT_PROTOCOL` | §6.3 |
| Argument is an expression | `FORBIDDEN_ARGUMENT_EXPRESSION` | §6.4 |
| String literal argument quoted incorrectly | `MALFORMED_ARGUMENT_QUOTING` | §6.4 |
| Argument list malformed | `MALFORMED_ARGUMENT_LIST` | §6.4 |
| Helper emits page-prefixed function call | `FORBIDDEN_HELPER_PAGE_FUNCTION_CALL` | §6.6 |

### 12.7 data-* attribute forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| `data-*` attribute name uses forbidden characters | `MALFORMED_DATA_ATTRIBUTE_NAME` | §7.2 |
| `data-*` value mixes static text with PS interpolation | `FORBIDDEN_INLINE_DATA_INTERPOLATION` | §7.2 |
| Helper emits page-specific `data-*` attribute | `FORBIDDEN_HELPER_PAGE_DATA_ATTRIBUTE` | §7.5 |

### 12.8 Text content forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| Text contains forbidden interpolation pattern | `MALFORMED_TEXT_INTERPOLATION` | §8.6 |
| User-facing attribute declared with empty value | `EMPTY_DISPLAY_TEXT` | §8.6 |

### 12.9 SVG forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| SVG markup contains forbidden interpolation pattern | `MALFORMED_SVG_INTERPOLATION` | §9.6 |

### 12.10 Comment forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| Comment body contains `--` (other than closing `-->`) | `MALFORMED_COMMENT_DASHES` | §10.6 |
| Comment contains PowerShell variable interpolation | `FORBIDDEN_COMMENT_INTERPOLATION` | §10.6 |
| Comment unclosed | `MALFORMED_COMMENT_UNCLOSED` | §10.6 |

### 12.11 Inline `<style>` blocks

Inline `<style>` blocks are forbidden in HTML markup with two exceptions:

- `Get-AccessDeniedHtml` (per §1.6) — exempt because the page renders before authenticated resources are reachable
- SVG-internal `<style>` (per §9.5) — exempt because it is SVG-scoped, not HTML-scoped

A `<style>` block in any other location emits `FORBIDDEN_INLINE_STYLE_BLOCK`.

### 12.12 Inline `<script>` blocks

Inline `<script>` blocks containing JavaScript code are forbidden in HTML markup. The only permitted form of `<script>` element is the asset reference form (`<script src="..."></script>`) per §3.2. A `<script>` element with body content (e.g., `<script>doSomething();</script>`) emits `FORBIDDEN_INLINE_SCRIPT_BLOCK`.

---
## 13. Catalog model

The HTML populator emits rows into `dbo.Asset_Registry` representing every catalogable construct found in HTML markup. This section describes the catalog model as it relates to HTML rows.

### 13.1 What the catalog represents

A row's identity is described by the combination of `component_type`, `component_name`, `reference_type`, `file_name`, and `occurrence_index`. The HTML populator emits one row per definition or usage instance found while walking the HTML markup inside PS string tokens.

The catalog is the authoritative answer to questions like: "where is the `bsv-modal-detail` ID declared?", "how many pages emit engine cards?", "what tooltip text appears on the page refresh button across pages?", "which HTML files contain spec drift today, and of what kinds?". Every such question becomes a SQL query against this table.

### 13.2 HTML-relevant component_type values

| `component_type` | Source | Meaning |
|---|---|---|
| `FILE_HEADER` | The PS file containing HTML emission | One row per scanned PS file. Anchors the file in the catalog regardless of HTML content. (Note: this row is emitted by the PS populator, not the HTML populator. Mentioned here because it scopes HTML rows.) |
| `HTML_ID` | `id="..."` attributes | One row per ID declaration. Resolved against `getElementById` calls in JS for cross-population linkage. |
| `HTML_DATA_ATTRIBUTE` | `data-*` attributes | One row per data-* attribute declaration. Resolved against JS `dataset.foo` reads for cross-population linkage. |
| `HTML_TEXT` | Element text content and four user-facing attribute values (`title`, `placeholder`, `aria-label`, `alt`) | One row per text node or attribute value. Categorical naming per §8.2.2. |
| `HTML_ENTITY` | HTML entity references (`&times;`, `&#9881;`) and direct Unicode characters | One row per entity or special character. Three forms catalogued per §8.3.1. |
| `HTML_SVG` | Inline `<svg>` elements | One row per outer `<svg>` element. Internals stored in `raw_text` (§9.1). |
| `HTML_COMMENT` | HTML comments | One row per recognized comment kind (§10.5.1). |
| `CSS_CLASS` | `class="..."` attribute values | One row per class name in the attribute. Resolves against CSS_CLASS DEFINITION rows (§5.6). |
| `JS_FUNCTION` | Event handler attributes (`onclick="..."`, etc.) | One row per function call in the handler. Resolves against JS_FUNCTION DEFINITION rows (§6.5). |

The CSS_CLASS USAGE rows from HTML markup share the `component_type` value with CSS_CLASS DEFINITION rows from CSS files; the `reference_type` and `scope` columns distinguish them.

### 13.3 reference_type values for HTML rows

For HTML markup, every row is emitted as a DEFINITION:

- `id="..."` declarations are HTML_ID DEFINITION rows (declarations of the ID)
- `data-*` declarations are HTML_DATA_ATTRIBUTE DEFINITION rows
- text nodes are HTML_TEXT DEFINITION rows
- comments are HTML_COMMENT DEFINITION rows
- SVG elements are HTML_SVG DEFINITION rows
- entity references are HTML_ENTITY DEFINITION rows

Two row types are USAGE rows because they reference constructs defined elsewhere:

- `class="..."` produces CSS_CLASS USAGE rows (the class is *defined* in CSS files)
- event handlers produce JS_FUNCTION USAGE rows (the function is *defined* in JS files)

### 13.4 Drift recording

The HTML populator evaluates every row against the spec and records two things when the row deviates:

- `drift_codes` — comma-separated list of stable short codes (e.g., `MISSING_PREFIX_ID,DUPLICATE_ID_DECLARATION`)
- `drift_text` — joined human-readable descriptions corresponding to each code

A row may carry zero, one, or many drift codes. Both columns are NULL when the row is fully spec-compliant. Empty strings are treated as NULL.

### 13.5 has_dynamic_content flag

The `has_dynamic_content` BIT column is set TRUE on rows where the parent attribute or text construct contains additional runtime-only content the populator cannot statically resolve. See §5.5 (class attributes), §8.5 (text), §9.4 (SVG), and the JS spec for JS-side application. A FALSE or NULL value means the row's parent construct is fully captured in the catalog.

### 13.6 Cross-populator dependencies

The HTML populator's emitted rows depend on populator pipeline ordering:

- `CSS_CLASS USAGE` rows have `scope` and `source_file` resolved against `CSS_CLASS DEFINITION` rows already in the catalog at HTML-populator scan time. Per pipeline order CSS → HTML → JS → PS, CSS DEFINITION rows always exist when HTML scans.
- `HTML_ID DEFINITION` rows are produced by HTML and consumed by JS. Per pipeline order, JS scans after HTML, so JS USAGE rows resolve against HTML DEFINITION rows.
- `HTML_DATA_ATTRIBUTE DEFINITION` rows are produced by HTML and consumed by JS. Same pipeline relationship.
- `parent_object` on HTML rows is populated by the PS populator (which runs after HTML) with the route path enclosing the markup.

When a populator runs standalone (out of pipeline order), unresolved cross-populator references resolve to `<undefined>` for `source_file` and `LOCAL` for `scope`. Standalone runs are valid for development and testing; production pipeline runs always follow the CSS → HTML → JS → PS order.

---
## 14. What the parser extracts

This table maps source HTML constructs to the catalog rows the HTML populator emits. The populator walks HTML markup inside PS string tokens, identifies recognized constructs, and emits rows accordingly.

| Source construct | Row type | Key columns |
|---|---|---|
| Page-level HTML emission (route file) | Implicit context | Establishes file_name, route path (later filled in by PS populator), parent_function, and source_section (banner context from PS file) |
| `id="..."` attribute on any element | `HTML_ID DEFINITION` | `component_name` = the ID value, `signature` = `id="<value>"` |
| `data-*="..."` attribute on any element | `HTML_DATA_ATTRIBUTE DEFINITION` | `component_name` = the attribute name including `data-`, `signature` = the full attribute |
| Element text node (non-whitespace character data between opening and closing tags) | `HTML_TEXT DEFINITION` | `component_name` = categorical name per §8.2.2, `raw_text` = literal text |
| `title="..."` attribute value | `HTML_TEXT DEFINITION` | `component_name` = `attr-title`, `raw_text` = literal value |
| `placeholder="..."` attribute value | `HTML_TEXT DEFINITION` | `component_name` = `attr-placeholder`, `raw_text` = literal value |
| `aria-label="..."` attribute value | `HTML_TEXT DEFINITION` | `component_name` = `attr-aria-label`, `raw_text` = literal value |
| `alt="..."` attribute value | `HTML_TEXT DEFINITION` | `component_name` = `attr-alt`, `raw_text` = literal value |
| HTML entity reference (`&named;`) | `HTML_ENTITY DEFINITION` | `component_name` = the literal entity, `signature` = `entity_named` |
| HTML numeric entity reference (`&#NNN;`) | `HTML_ENTITY DEFINITION` | `component_name` = the literal entity, `signature` = `entity_numeric` |
| Direct Unicode character (above basic ASCII range) | `HTML_ENTITY DEFINITION` | `component_name` = the literal character, `signature` = `direct_unicode` |
| `<svg>...</svg>` element | `HTML_SVG DEFINITION` | `component_name` = categorical name per §9.3, `raw_text` = full SVG markup |
| HTML comment (`<!-- ... -->`) | `HTML_COMMENT DEFINITION` | `component_name` = categorical name per §10.5.1, `raw_text` = full comment text |
| Each class name in `class="..."` (one row per class) | `CSS_CLASS USAGE` | `component_name` = the class name, `signature` = full attribute value, `has_dynamic_content` per §5.5 |
| Each function call in event handler (`onclick="..."` etc.) | `JS_FUNCTION USAGE` | `component_name` = the function name, `signature` = full attribute |
| `<link rel="stylesheet" href="...">` reference | `CSS_FILE USAGE` | `component_name` = the href value, resolved against CSS_FILE DEFINITION rows |
| `<script src="..."></script>` reference | `JS_FILE USAGE` | `component_name` = the src value, resolved against JS_FILE DEFINITION rows |

Each emitted row carries its `drift_codes` and `drift_text` columns populated when the row violates a spec rule. Rows with no violations have NULL drift columns.

The populator does not emit rows for:

- Whitespace between elements (newlines, indentation spaces)
- Element tag names themselves (the populator extracts attributes and text but does not catalog the tag as a separate row; tag context is preserved via categorical naming and `parent_function`)
- Attribute names that are not in the catalogued attribute set (the populator catalogs `id`, `class`, `data-*`, the four user-facing attributes, asset reference attributes, and event handler attributes; other attributes like `width`, `height`, `viewBox` on SVG, or `type`, `name`, `disabled` on form fields are not emitted as rows but are stored as part of `raw_text` on parent rows)

---
## 15. Drift codes reference

The HTML populator may emit any of the following drift codes on emitted rows. Codes are organized by spec section. For the full pattern-to-code mapping, see Section 12 (Forbidden patterns).

### 15.1 Page shell codes (§1)

| Code | Description |
|---|---|
| `MALFORMED_DOCTYPE` | The HTML document does not open with `<!DOCTYPE html>` on its own line, or the DOCTYPE token uses mixed case. |
| `MALFORMED_HTML_ROOT` | The root `<html>` element has attributes (e.g., `<html lang="en">`); attributes are not permitted on the root element. |
| `MALFORMED_HEAD` | The `<head>` element contains constructs other than `<title>` and `<link>` (e.g., inline `<style>`, `<meta>`, `<script>`). |
| `FORBIDDEN_HARDCODED_TITLE` | The `<title>` content is a hardcoded string instead of the `$browserTitle` PowerShell variable substitution. |
| `MISSING_BODY_SECTION_CLASS` | The `<body>` element does not declare a `class="section-<sectionKey>"` attribute. |
| `MISSING_NAV_SUBSTITUTION` | The first content inside `<body>` is not the `$navHtml` substitution. |
| `MALFORMED_BODY_CLOSE` | Content appears between the JS reference block and `</body>`. |
| `MISSING_HEADER_BAR` | The page header bar is missing as the first content after `$navHtml`. |
| `FORBIDDEN_HARDCODED_PAGE_HEADER` | The page header content is hardcoded instead of the `$headerHtml` PowerShell variable substitution. |
| `MISSING_CONNECTION_BANNER` | The connection banner placeholder is missing. |
| `FORBIDDEN_BANNER_CONTENT` | The connection banner placeholder contains content (it must be empty). |

### 15.2 Page chrome codes (§2)

| Code | Description |
|---|---|
| `MALFORMED_HEADER_BAR_CONTAINER` | The header bar's outer container is not `<div class="header-bar">`. |
| `MALFORMED_HEADER_BAR_LEFT` | The first child of `header-bar` is not the unattributed `<div>` containing the `$headerHtml` substitution. |
| `MALFORMED_HEADER_BAR_RIGHT` | The second child of `header-bar` is not `<div class="header-right">`. |
| `MALFORMED_HEADER_RIGHT_CHILDREN` | The `header-right` element contains children other than `refresh-info` and optional `engine-row`. |
| `MALFORMED_REFRESH_INFO_CONTAINER` | The refresh info block's outer container is not `<div class="refresh-info">`. |
| `MALFORMED_LIVE_INDICATOR` | The live indicator span is malformed; expected `<span class="live-indicator"></span>` exactly. |
| `MALFORMED_LIVE_STATUS_LINE` | The live status line ("`Live | Updated:`") deviates from mandated form. |
| `MALFORMED_REFRESH_BUTTON` | The page refresh button markup deviates from mandated form (class, onclick, title, or entity reference). |
| `DUPLICATE_LAST_UPDATE_ID` | The `last-update` ID appears more than once on the page. |
| `MALFORMED_ENGINE_ROW_CONTAINER` | The engine row's outer container is not `<div class="engine-row">`. |
| `MALFORMED_ENGINE_ROW_CHILDREN` | The engine row contains children other than engine cards. |
| `ENGINE_CARD_ORDER_MISMATCH` | Engine cards are not in declaration order matching `cc_sort_order`. |
| `MALFORMED_ENGINE_CARD` | An engine card's structure deviates from the mandated four-element block. |
| `MALFORMED_ENGINE_CARD_ATTRIBUTES` | An engine card's attributes are malformed (class or ID). |
| `MALFORMED_ENGINE_LABEL` | An engine label span is malformed (class or text). |
| `MALFORMED_ENGINE_BAR` | An engine bar div is malformed (class or ID, or contains content). |
| `MALFORMED_ENGINE_COUNTDOWN` | An engine countdown span is malformed (class, ID, or content). |
| `MISSING_ENGINE_CARD_REGISTRATION` | An active scheduled process (`run_mode = 1`) has NULL values in `cc_engine_slug`, `cc_engine_label`, `cc_page_route`, or `cc_sort_order`. |
| `UNEXPECTED_ENGINE_CARD_REGISTRATION` | A queue processor process (`run_mode = 2`) has populated values in `cc_engine_slug`, `cc_engine_label`, `cc_page_route`, or `cc_sort_order`. |
| `ENGINE_SLUG_REGISTRY_MISMATCH` | The slug used in card IDs doesn't match `Orchestrator.ProcessRegistry.cc_engine_slug` for the corresponding process. |
| `ENGINE_LABEL_REGISTRY_MISMATCH` | The label text in the engine label span doesn't match `Orchestrator.ProcessRegistry.cc_engine_label`. |
| `ENGINE_CARD_PAGE_MISMATCH` | An engine card appears on a page whose route doesn't match `Orchestrator.ProcessRegistry.cc_page_route`. |

### 15.3 Asset reference codes (§3)

| Code | Description |
|---|---|
| `MALFORMED_CSS_LINK` | A `<link>` element uses additional attributes beyond `rel="stylesheet"` and `href="..."`, or has an incorrect form. |
| `MALFORMED_PAGE_CSS_REFERENCE` | The page-specific CSS reference's `href` doesn't match `/css/<page>.css` form. |
| `MALFORMED_SHARED_CSS_REFERENCE` | The shared CSS reference is not exactly `<link rel="stylesheet" href="/css/cc-shared.css">`. |
| `CSS_REFERENCE_ORDER_VIOLATION` | The page-specific CSS reference does not appear before the shared reference. |
| `UNEXPECTED_CSS_REFERENCE` | A page references more or fewer than two CSS files in `<head>`. |
| `MALFORMED_JS_SCRIPT` | A `<script>` element uses additional attributes (e.g., `defer`, `async`) or has body content. |
| `MALFORMED_PAGE_JS_REFERENCE` | The page-specific JS reference's `src` doesn't match `/js/<page>.js` form. |
| `MALFORMED_SHARED_JS_REFERENCE` | The shared JS reference is not exactly `<script src="/js/cc-shared.js"></script>`. |
| `JS_REFERENCE_ORDER_VIOLATION` | The page-specific JS reference does not appear before the shared reference. |
| `UNEXPECTED_JS_REFERENCE` | A page references more or fewer than two JS files in `<body>`. |
| `JS_REFERENCE_NOT_LAST` | Content appears between the JS reference block and `</body>`. |
| `FORBIDDEN_HELPER_ASSET_REFERENCE` | A helper module function emits a `<link>` or `<script>` element. |

### 15.4 ID codes (§4)

| Code | Description |
|---|---|
| `CHROME_ID_REUSED_AS_LOCAL` | A page-local element is assigned a chrome ID (e.g., `id="last-update"` on a non-chrome element). |
| `MISSING_PREFIX_ID` | A page-local ID does not begin with the page's `cc_prefix` followed by a hyphen. |
| `CROSS_PAGE_PREFIX_COLLISION` | A page-local ID begins with another page's prefix. |
| `DUPLICATE_ID_DECLARATION` | The same ID value is declared more than once on a page. |
| `MALFORMED_ID_VALUE` | An ID value contains characters other than lowercase letters, digits, and hyphens. |
| `MALFORMED_SLIDEOUT_ID` | A slideout overlay or panel ID does not follow `<prefix>-slideout-<purpose>-*` form. |
| `MALFORMED_MODAL_ID` | A modal overlay or dialog ID does not follow `<prefix>-modal-<purpose>-*` form. |
| `MALFORMED_SLIDEUP_ID` | A slide-up panel backdrop or panel ID does not follow `<prefix>-slideup-<purpose>-*` form. |
| `INCOMPLETE_OVERLAY_PAIR` | A slideout, modal, or slide-up panel declares one half of the overlay/panel pair without the other. |
| `MISSING_PANEL_PURPOSE_COMMENT` | A slideout, modal, or slide-up panel declaration is not preceded by an HTML purpose comment. |
| `FORBIDDEN_HELPER_PAGE_PREFIX_ID` | A helper module function emits HTML with a page-prefixed ID. |

### 15.5 Class attribute codes (§5)

| Code | Description |
|---|---|
| `MALFORMED_CLASS_VALUE_WHITESPACE` | A class attribute value contains multiple consecutive spaces, leading/trailing whitespace, or tabs. |
| `MALFORMED_CLASS_NAME` | A class name contains characters other than lowercase letters, digits, and hyphens. |
| `DUPLICATE_CLASS_IN_VALUE` | The same class name appears more than once in the same `class` attribute. |
| `CLASS_PREFIX_MISMATCH` | A class name doesn't begin with the page's `cc_prefix` and is not defined in `cc-shared.css`. |
| `INLINE_CLASS_CONCATENATION` | A class attribute uses inline interpolation appended to static text (e.g., `class="nav-link$accent"`). |
| `INLINE_CLASS_PREFIX_MIX` | A class attribute uses inline interpolation followed or preceded by static text (e.g., `class="$type wide"`). |
| `INLINE_CLASS_MULTI_INTERPOLATION` | A class attribute uses multiple top-level interpolations without using the array-join pattern. |
| `INLINE_CLASS_BRACED_INTERPOLATION` | A class attribute uses PowerShell `${...}` or `$(...)` form mixed with static text. |

### 15.6 Event handler codes (§6)

| Code | Description |
|---|---|
| `MULTIPLE_HANDLER_STATEMENTS` | An event handler attribute contains multiple statements (e.g., `onclick="doA(); doB()"`). |
| `INLINE_HANDLER_EXPRESSION` | An event handler attribute contains expressions other than a single function call. |
| `MALFORMED_HANDLER_CALL` | An event handler's function call has whitespace between the function name and the opening parenthesis. |
| `TRAILING_HANDLER_SEMICOLON` | An event handler attribute ends with a trailing semicolon. |
| `FORBIDDEN_REVEALING_MODULE_CALL` | An event handler calls a function via dotted property access (e.g., `Module.func()`). |
| `FORBIDDEN_BUILTIN_METHOD_CALL` | An event handler calls a method on a built-in object (e.g., `window.location.href = ...`). |
| `HANDLER_FUNCTION_NAME_MISMATCH` | An event handler's function name is not registered as chrome and does not match the page's prefix. |
| `FORBIDDEN_EVENT_METHOD_CALL` | An event handler calls a method on the event object (e.g., `event.stopPropagation()`). |
| `FORBIDDEN_HANDLER_CONDITIONAL` | An event handler contains conditional logic (e.g., `if (event.key === 'Enter') ...`). |
| `FORBIDDEN_INLINE_DOM_OPERATION` | An event handler performs DOM manipulation inline (e.g., `this.classList.toggle(...)`). |
| `FORBIDDEN_INLINE_ASSIGNMENT` | An event handler contains assignment expressions (e.g., `this.value = ...`). |
| `FORBIDDEN_JAVASCRIPT_PROTOCOL` | An event handler uses the `javascript:` pseudo-protocol. |
| `FORBIDDEN_ARGUMENT_EXPRESSION` | An event handler argument is an expression other than a literal, `this`, or `this.<property>`. |
| `MALFORMED_ARGUMENT_QUOTING` | A string literal argument uses double quotes (which conflict with the surrounding attribute value's quoting). |
| `MALFORMED_ARGUMENT_LIST` | Multiple arguments are not separated by `, ` (comma followed by single space). |
| `FORBIDDEN_HELPER_PAGE_FUNCTION_CALL` | A helper module function emits an event handler that calls a page-prefixed function. |

### 15.7 data-* attribute codes (§7)

| Code | Description |
|---|---|
| `MALFORMED_DATA_ATTRIBUTE_NAME` | A `data-*` attribute name contains characters other than lowercase letters, digits, and hyphens after the `data-` prefix. |
| `FORBIDDEN_INLINE_DATA_INTERPOLATION` | A `data-*` attribute value mixes static text with PowerShell interpolation. |
| `FORBIDDEN_HELPER_PAGE_DATA_ATTRIBUTE` | A helper module function emits a `data-*` attribute that is page-specific. |

### 15.8 Text content codes (§8)

| Code | Description |
|---|---|
| `MALFORMED_TEXT_INTERPOLATION` | Text content contains PowerShell variable interpolation that uses forbidden patterns from §5.2.3. |
| `EMPTY_DISPLAY_TEXT` | A user-facing attribute (`title`, `placeholder`, `aria-label`, `alt`) is declared with an empty value. |

### 15.9 SVG codes (§9)

| Code | Description |
|---|---|
| `MALFORMED_SVG_INTERPOLATION` | An SVG element's outer markup contains forbidden interpolation patterns. |

### 15.10 Comment codes (§10)

| Code | Description |
|---|---|
| `MALFORMED_COMMENT_DASHES` | An HTML comment body contains `--` other than the closing `-->`. |
| `FORBIDDEN_COMMENT_INTERPOLATION` | An HTML comment contains PowerShell variable interpolation. |
| `MALFORMED_COMMENT_UNCLOSED` | An HTML comment's opening `<!--` does not have a matching closing `-->`. |

### 15.11 Inline asset block codes (§12)

| Code | Description |
|---|---|
| `FORBIDDEN_INLINE_STYLE_BLOCK` | A `<style>` block appears in HTML markup outside the §1.6 (access-denied page) and §9.5 (SVG-internal) carve-outs. |
| `FORBIDDEN_INLINE_SCRIPT_BLOCK` | A `<script>` element contains body content (i.e., is not the asset reference form `<script src="..."></script>`). |

---
## 16. Compliance queries

Standard SQL queries against `dbo.Asset_Registry` for HTML compliance reporting. Each query is scoped to `WHERE file_type = 'HTML'` (or includes related cross-population scopes where indicated).

### 16.1 Q1 — Drift summary per file

Counts of total HTML rows and rows-with-drift per file. Use to prioritize refactor work.

```sql
SELECT
    file_name,
    COUNT(*)                                                     AS total_rows,
    SUM(CASE WHEN drift_codes IS NOT NULL THEN 1 ELSE 0 END)     AS rows_with_drift
FROM dbo.Asset_Registry
WHERE file_type = 'HTML'
GROUP BY file_name
ORDER BY rows_with_drift DESC;
```

### 16.2 Q2 — Drift code distribution

What kinds of drift are most common across the HTML codebase?

```sql
SELECT
    TRIM(value)         AS code,
    COUNT(*)            AS occurrences
FROM dbo.Asset_Registry
CROSS APPLY STRING_SPLIT(drift_codes, ',')
WHERE file_type    = 'HTML'
  AND drift_codes  IS NOT NULL
  AND TRIM(value)  <> ''
GROUP BY TRIM(value)
ORDER BY COUNT(*) DESC;
```

### 16.3 Q3 — Per-file rewrite checklist

For one specific file, what does the work look like, grouped by drift code?

```sql
SELECT
    drift_codes,
    COUNT(*)            AS occurrences,
    MIN(line_start)     AS first_line,
    MAX(line_start)     AS last_line
FROM dbo.Asset_Registry
WHERE file_type    = 'HTML'
  AND file_name    = '<filename.ps1>'
  AND drift_codes  IS NOT NULL
GROUP BY drift_codes
ORDER BY occurrences DESC;
```

### 16.4 Q4 — Cross-page text comparison

For each text categorical name, list every page's variation. Surfaces copy inconsistency.

```sql
SELECT
    component_name        AS category,
    file_name,
    raw_text
FROM dbo.Asset_Registry
WHERE file_type      = 'HTML'
  AND component_type = 'HTML_TEXT'
ORDER BY component_name, file_name;
```

### 16.5 Q5 — Engine card registry validation

Which active scheduled processes lack engine card registration, or are registered to non-existent pages?

```sql
SELECT
    process_id,
    process_name,
    run_mode,
    cc_engine_slug,
    cc_engine_label,
    cc_page_route,
    cc_sort_order,
    CASE
        WHEN run_mode = 1 AND (cc_engine_slug IS NULL OR cc_engine_label IS NULL OR cc_page_route IS NULL OR cc_sort_order IS NULL)
            THEN 'Active scheduled process missing engine card registration'
        WHEN run_mode = 2 AND (cc_engine_slug IS NOT NULL OR cc_engine_label IS NOT NULL OR cc_page_route IS NOT NULL OR cc_sort_order IS NOT NULL)
            THEN 'Queue processor has unexpected engine card registration'
        ELSE NULL
    END AS issue
FROM Orchestrator.ProcessRegistry
WHERE run_mode IN (1, 2)
  AND (
      (run_mode = 1 AND (cc_engine_slug IS NULL OR cc_engine_label IS NULL OR cc_page_route IS NULL OR cc_sort_order IS NULL))
      OR
      (run_mode = 2 AND (cc_engine_slug IS NOT NULL OR cc_engine_label IS NOT NULL OR cc_page_route IS NOT NULL OR cc_sort_order IS NOT NULL))
  );
```

### 16.6 Q6 — Slideout/modal/panel inventory

List every slideout, modal, and slide-up panel platform-wide, grouped by construct kind.

```sql
SELECT
    file_name,
    component_name,
    purpose_description,
    drift_codes
FROM dbo.Asset_Registry
WHERE file_type      = 'HTML'
  AND component_type = 'HTML_ID'
  AND reference_type = 'DEFINITION'
  AND (
      component_name LIKE '%-slideout-%'
      OR component_name LIKE '%-modal-%'
      OR component_name LIKE '%-slideup-%'
  )
ORDER BY component_name, file_name;
```

### 16.7 Q7 — Cross-form entity inventory

Find every distinct icon/symbol used platform-wide across all three forms (named entity, numeric entity, direct Unicode).

```sql
SELECT
    component_name,
    signature              AS form,
    COUNT(DISTINCT file_name) AS appears_on_n_pages,
    STRING_AGG(file_name, ', ') WITHIN GROUP (ORDER BY file_name) AS files
FROM dbo.Asset_Registry
WHERE file_type      = 'HTML'
  AND component_type = 'HTML_ENTITY'
GROUP BY component_name, signature
ORDER BY appears_on_n_pages DESC, component_name;
```

Q7 surfaces three-form inconsistencies — where the same conceptual icon (e.g., a gear) appears as `&#9881;` on one page and `⚙` on another.

### 16.8 Q8 — Unresolved cross-population references

Find every CSS_CLASS USAGE or JS_FUNCTION USAGE row from HTML where the referenced construct doesn't have a matching DEFINITION row.

```sql
SELECT
    file_name,
    component_type,
    component_name,
    line_start
FROM dbo.Asset_Registry
WHERE file_type    = 'HTML'
  AND reference_type = 'USAGE'
  AND source_file  = '<undefined>'
ORDER BY component_type, component_name, file_name;
```

### 16.9 Q9 — Helper coupling check

Find any helper-emitted HTML that has page-prefixed IDs, page-prefixed function calls, or page-specific data-* attributes (all forbidden by helper rules).

```sql
SELECT
    file_name,
    component_type,
    component_name,
    parent_function,
    drift_codes
FROM dbo.Asset_Registry
WHERE file_type   = 'HTML'
  AND scope       = 'SHARED'
  AND drift_codes LIKE '%FORBIDDEN_HELPER_%'
ORDER BY file_name, component_name;
```

### 16.10 Q10 — Has-dynamic-content inventory

Find every catalog row where the parent attribute or text construct contains additional runtime-only content.

```sql
SELECT
    file_name,
    component_type,
    component_name,
    raw_text
FROM dbo.Asset_Registry
WHERE has_dynamic_content = 1
ORDER BY file_name, line_start;
```

This query identifies places where the catalog's static analysis is incomplete by design, useful for distinguishing "the catalog has the full picture" from "the catalog has a partial picture."

---
## 17. Examples

### 17.1 Minimal complete page emission

A small page demonstrating every required pattern. Real pages have more sections.

```html
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>
    <link rel="stylesheet" href="/css/example.css">
    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="section-platform">
$navHtml

<div class="header-bar">
    <div>
        $headerHtml
    </div>
    <div class="header-right">
        <div class="refresh-info">
            <span class="live-indicator"></span>
            <span>Live</span> | Updated: <span id="last-update" class="last-updated">-</span>
            <button class="page-refresh-btn" onclick="pageRefresh()" title="Refresh all data">&#8635;</button>
        </div>
    </div>
</div>

<div id="connection-banner" class="connection-banner"></div>

<div class="exa-page-grid">
    <div class="exa-status-card">
        <h2 class="exa-section-title">Status Overview</h2>
        <p class="exa-message">Loading data...</p>
    </div>
</div>

<script src="/js/example.js"></script>
<script src="/js/cc-shared.js"></script>
</body>
</html>
```

This emission produces these catalog rows (illustrative, not exhaustive):

- 1 × `HTML_ID DEFINITION` for `last-update` (chrome ID)
- 1 × `HTML_ID DEFINITION` for `connection-banner` (chrome ID)
- Multiple × `CSS_CLASS USAGE` rows resolving to either `cc-shared.css` (chrome classes) or `example.css` (page classes)
- 2 × `JS_FUNCTION USAGE` rows for `pageRefresh()` (chrome) and any page-specific handlers
- 2 × `CSS_FILE USAGE` rows for the two stylesheet references
- 2 × `JS_FILE USAGE` rows for the two script references
- Several × `HTML_TEXT DEFINITION` rows: `attr-title` for the refresh button tooltip, `h2-section-title`, `p-message`, etc.
- 1 × `HTML_ENTITY DEFINITION` for `&#8635;` with `signature = entity_numeric`

Zero drift rows expected when the page conforms.

### 17.2 Engine card block

Three engine cards on a page that consumes orchestrator events:

```html
<div class="engine-row">
    <div class="engine-card" id="card-engine-nb">
        <span class="engine-label">NB</span>
        <div class="engine-bar disabled" id="engine-bar-nb"></div>
        <span class="engine-countdown" id="engine-cd-nb">&nbsp;</span>
    </div>
    <div class="engine-card" id="card-engine-pmt">
        <span class="engine-label">PMT</span>
        <div class="engine-bar disabled" id="engine-bar-pmt"></div>
        <span class="engine-countdown" id="engine-cd-pmt">&nbsp;</span>
    </div>
    <div class="engine-card" id="card-engine-bdl">
        <span class="engine-label">BDL</span>
        <div class="engine-bar disabled" id="engine-bar-bdl"></div>
        <span class="engine-countdown" id="engine-cd-bdl">&nbsp;</span>
    </div>
</div>
```

Each card produces three `HTML_ID DEFINITION` rows (the three IDs) plus the corresponding text content rows for the labels. Cross-validation against `Orchestrator.ProcessRegistry` confirms slugs (`nb`, `pmt`, `bdl`), labels (`NB`, `PMT`, `BDL`), and that all three processes have `cc_page_route = '/batch-monitoring'`.

### 17.3 Dynamic class assembly

Building a navigation link with conditional state classes:

```powershell
$classList = @('nav-link')
if ($section.accent_class) { $classList += $section.accent_class }
if ($page.page_route -eq $CurrentPageRoute) { $classList += 'active' }
$cssClasses = ($classList -join ' ')

[void]$sb.AppendLine("<a href=`"$($page.page_route)`" class=`"$cssClasses`">$($page.page_label)</a>")
```

The populator emits:

- `CSS_CLASS USAGE` for `nav-link` (literal in array initialization), `has_dynamic_content = TRUE`
- `CSS_CLASS USAGE` for `active` (literal in conditional append), `has_dynamic_content = TRUE`
- No row for `$section.accent_class` (parameter-fed, not statically resolvable)

The flag indicates that the catalog's view of these class compositions is partial — the runtime may add `nav-section-platform` or `nav-section-departmental` depending on the section.

### 17.4 Slideout with purpose comment

```html
<!-- Slideout for displaying request details with comments and timeline -->
<div id="bsv-slideout-request-overlay" class="slide-panel-overlay" onclick="bsv_closeRequestSlideout()"></div>
<div id="bsv-slideout-request" class="slide-panel xwide">
    <div class="slide-panel-header">
        <h3 class="bsv-slideout-title">Request Details</h3>
        <button class="slide-panel-close" onclick="bsv_closeRequestSlideout()" title="Close">×</button>
    </div>
    <div class="slide-panel-body" id="bsv-slideout-request-body"></div>
</div>
```

Catalog rows emitted:

- `HTML_COMMENT DEFINITION` for the comment, `component_name = comment-panel-purpose`
- `HTML_ID DEFINITION` for `bsv-slideout-request-overlay`, `purpose_description` populated from comment
- `HTML_ID DEFINITION` for `bsv-slideout-request`, `purpose_description` populated from comment
- `HTML_ID DEFINITION` for `bsv-slideout-request-body`
- `JS_FUNCTION USAGE` for `bsv_closeRequestSlideout()` (twice — overlay and close button)
- `HTML_TEXT DEFINITION` for "Request Details" with `component_name = h3-slideout-title`
- `HTML_TEXT DEFINITION` for "×" (the close glyph) — actually emitted as `HTML_ENTITY DEFINITION` with `signature = direct_unicode`
- `HTML_TEXT DEFINITION` for "Close" attribute value with `component_name = attr-title`

### 17.5 Anti-pattern: forbidden inline class composition

Anti-pattern (forbidden — emits multiple drift codes):

```powershell
$activeClass = if ($page.page_route -eq $CurrentPageRoute) { ' active' } else { '' }
[void]$sb.AppendLine("<a class=`"nav-link$($section.accent_class)$activeClass`">$label</a>")
```

This emits `INLINE_CLASS_CONCATENATION`, `INLINE_CLASS_BRACED_INTERPOLATION`, and possibly other codes depending on the populator's evaluation order.

Correct pattern (per §5.2.1):

```powershell
$classList = @('nav-link')
if ($section.accent_class) { $classList += $section.accent_class }
if ($page.page_route -eq $CurrentPageRoute) { $classList += 'active' }
$cssClasses = ($classList -join ' ')
[void]$sb.AppendLine("<a class=`"$cssClasses`">$label</a>")
```

The correct pattern produces clean catalog rows with no drift.

### 17.6 Anti-pattern: inline event handler logic

Anti-pattern (forbidden):

```html
<button onclick="if(event.target.dataset.confirmed === 'true') deleteItem(123)">Delete</button>
```

This emits `INLINE_HANDLER_EXPRESSION`, `FORBIDDEN_HANDLER_CONDITIONAL`, and `FORBIDDEN_EVENT_METHOD_CALL` (since `event.target.dataset` is method/property access on the event object).

Correct pattern (per §6):

```html
<button onclick="bsv_deleteItemIfConfirmed(this, 123)">Delete</button>
```

```javascript
function bsv_deleteItemIfConfirmed(button, itemId) {
    if (button.dataset.confirmed === 'true') {
        bsv_deleteItem(itemId);
    }
}
```

The conditional logic moves to the JS function; the HTML stays declarative.

---
## Appendix - Rationale

This appendix explains why selected rules are what they are. Entries are keyed to body section numbers. Sections without entries here have no rationale beyond the rule itself.

### A.1 Required structure

The strict page shell shape (DOCTYPE, root, head, body, content order) is what lets the parser walk a route file's emitted HTML deterministically. Each emission has predictable phases the populator can recognize: file shell, chrome, content, asset references. Without a fixed shape, the populator would have to handle arbitrary structural variation, which inflates parser complexity for no platform benefit.

The page shell substitutions (`$browserTitle`, `$navHtml`, `$headerHtml`, `$sectionKey`) preserve the platform's centralized control over chrome behavior. If pages hardcoded their titles, headers, or section keys, every platform-wide chrome change would require touching every page. The substitution pattern lets `Get-PageBrowserTitle`, `Get-NavBarHtml`, and `Get-PageHeaderHtml` evolve independently of page authoring.

### A.2 Page chrome

The exact-markup mandate for chrome elements (refresh button entity reference, live indicator structure, engine card four-element block) is the spec's "design inconsistency surfacer" working as intended. Variations like "Refresh data" vs "Refresh all data" vs "Reload" are real inconsistencies that the catalog must distinguish between conforming and non-conforming. Loosening the rules to "any reasonable refresh button" defeats the purpose: the catalog can't surface variation it doesn't see as variation.

The engine card slug-from-registry rule (§2.3.3) makes ProcessRegistry the single source of truth for engine card identification. Without it, the slug exists in three places (registry, JS file, HTML IDs) and can drift between any of them. Tying all three to the registry value via cross-population rules ensures drift is detectable.

The `run_mode`-based validation rules (active scheduled processes must have card registration; queue processors must not) leverage existing schema columns rather than adding new ones. The discriminator already exists; the spec just makes the catalog enforce it.

### A.4 ID conventions

The closed set for chrome IDs (§4.1) is small by design. Chrome IDs represent platform-wide DOM contracts between `cc-shared.js` and the page. Letting pages add new chrome IDs unilaterally would mean shared JS code grows brittle dependencies on per-page identifiers. The "spec amendment required" gate forces deliberate platform decisions when shared infrastructure needs new DOM hooks.

The role-first ordering for slideout/modal/panel IDs (`<prefix>-slideout-<purpose>-overlay` rather than `<prefix>-<purpose>-slideout-overlay`) supports cross-page consistency queries: `LIKE 'bsv-slideout-%'` returns every slideout on a page; without role-first ordering, this query would need leading wildcards or lookups against tag-context.

Panel purpose comments (§4.3.5) exist because slideouts/modals/panels are the constructs that vary most in messaging across pages. Different pages have different request slideouts, different detail modals, different alert panels. Comparison queries against `purpose_description` for these constructs surface what each page actually does.

### A.5 Class attribute conventions

The single mandated dynamic class assembly pattern (array-join) deliberately constrains how class composition is expressed. Multiple legitimate-looking patterns exist for building dynamic strings (concatenation, here-strings, format operators, mixed interpolation), and a spec that allowed several would produce a catalog full of stylistically inconsistent rows that say the same thing.

Mandating one pattern means: catalogs are uniform, populator detection is simple (fail-on-deviation rather than recognize-many-variants), refactoring is mechanical (every dynamic class composition refactors to the same target shape), and code reviews are simpler ("does this match the pattern?").

The granular drift codes for forbidden interpolation patterns (§5.2.3) follow the CSS spec's banner-format precedent: `BANNER_INVALID_RULE_LENGTH`, `BANNER_INLINE_SHAPE`, `BANNER_MISSING_DESCRIPTION`, etc. are split rather than collapsed because each describes a specific kind of work to fix it. The same logic applies to inline class interpolation: `INLINE_CLASS_CONCATENATION` and `INLINE_CLASS_BRACED_INTERPOLATION` describe different syntactic problems requiring different mental refactor patterns, even though both end at the same array-join target.

The `has_dynamic_content` flag exists because static analysis cannot resolve parameter-passed class names. Without the flag, a catalog query like "what classes does `Get-NavBarHtml` apply to nav links?" returns an incomplete answer that looks complete. The flag makes incompleteness queryable: rows where the catalog knows there's more, but can't see it.

### A.6 Event handler conventions

The exactly-one-function-call rule expresses a separation of concerns: HTML is structural and declarative; JavaScript is behavioral and imperative. Inline expressions in handlers blur this line by putting JS-side logic into HTML-side markup. Forbidding the practice keeps the boundary clean: if a click should trigger conditional logic, the conditional lives in a JS function, not in the `onclick` attribute.

The forbidden revealing-module pattern (`Module.func()`) is forbidden because the CC platform doesn't use revealing modules. Pages declare functions at the module-top level (function-statement form). A handler calling `Admin.openX()` implies a module structure that isn't there; the call resolves to undefined at runtime.

The page-prefixed function rule for handlers (§6.2) ensures the catalog can distinguish chrome calls (used everywhere) from page-local calls (used on one page). Without a naming convention, a handler `onclick="closeMenu()"` is ambiguous: is this chrome or page-local? With prefixes, `closeMenu()` is chrome and `bsv_closeMenu()` is BusinessServices-local.

### A.7 data-* attribute conventions

The open-set policy for `data-*` names (no closed registry) reflects that data-* exists precisely to let pages attach arbitrary custom data without spec amendment. Forcing every distinct `data-*` name through a registry would defeat the attribute's purpose.

That said, the catalog tracks every distinct name. If patterns emerge — many pages using `data-batch-id`, `data-action`, etc. — the catalog query data informs whether a Phase 3 tightening is warranted (e.g., mandating that certain data-* names follow specific value formats).

### A.8 Text content and entity references

The categorical naming for HTML_TEXT rows (§8.2.2) supports the catalog's primary purpose for text: cross-page consistency comparison. Without categorical naming, queries like "all section titles platform-wide" would need to scan all `HTML_TEXT` rows and inspect parent elements at query time — slow and complex. With categorical naming, the same query is `WHERE component_name = 'h2-section-title'` — fast and indexable.

The page-prefix stripping in derivation handles a subtle issue: `<h2 class="bsv-section-title">` and `<h2 class="bch-section-title">` would otherwise have different `component_name` values (`h2-bsv-section-title` vs `h2-bch-section-title`), defeating cross-page comparison. Stripping the page prefix before deriving the category produces unified `h2-section-title` for both, which is the intent.

The decision not to mandate which form (named entity, numeric entity, direct Unicode) icons should use is a Phase 1 deferral. The catalog tracks all three forms; once data shows which forms are actually in use and where the inconsistencies are, Phase 3 tightening can mandate one form (likely numeric entities for typographic safety).

### A.9 Inline SVG

Treating SVG as opaque markup at the catalog level reflects a practical scoping choice. Deeply parsing SVG (paths, gradients, animations, text positioning) would be substantial parser work for limited catalog value. The current model (one row per outer `<svg>`, full markup in `raw_text`) supports both "what SVGs exist?" queries (against `component_name`) and "exact-content comparison" queries (against `raw_text`) without committing to internal parsing.

The §9.5 carve-out for SVG-internal `<style>` blocks recognizes that SVG has its own legitimate styling needs (gradients, animations) that can't reasonably move to external CSS. The carve-out is narrow — `<style>` is permitted only inside `<svg>` — and doesn't extend to HTML-scope `<style>` blocks anywhere else.

### A.13 Catalog model

The composite row identity (`component_type`, `component_name`, `reference_type`, `file_name`, `occurrence_index`) supports catalog queries that need different scoping. Same identifier can appear as a definition once and a usage many times; same file can have many rows of different types; same component_type can group across files. The composite identity makes all of these queryable.

The cross-populator dependency model (CSS → HTML → JS → PS) preserves single-pass resolution. Each populator runs against a catalog state where its dependencies have already emitted their rows. JS resolves IDs against HTML's DEFINITION rows; HTML resolves classes against CSS's DEFINITION rows. Standalone runs out of order produce `<undefined>` resolution, surfaced via the `source_file` column rather than as drift codes.

### A.15 Drift codes — granularity

The drift codes throughout the spec are granular by design — each describes one specific spec violation, not a general category. This mirrors the CSS spec's precedent (banner format codes, forbidden combinator codes) and serves the same purpose: precise refactor planning. A query for "every page with a malformed refresh button" returns rows with `MALFORMED_REFRESH_BUTTON`; a query for "every page with engine card label drift" returns rows with `ENGINE_LABEL_REGISTRY_MISMATCH`. The codes are the diagnostic vocabulary the catalog uses to describe what's wrong.

A coarser approach (one drift code per section, e.g., `MALFORMED_PAGE_CHROME`) would conflate many distinct violations and make refactor work harder to triage. The granular approach trades a higher code count for queryability — and the spec is the catalog's vocabulary, so vocabulary richness is a feature.
